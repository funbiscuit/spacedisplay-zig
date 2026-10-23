//! Pure scan/delete state machine: owns the tree, the job queues and
//! the counters. The caller pops a job with nextJob, runs it, and feeds
//! each fresh listing back. Mutex-guarded, thread-safe.

const std = @import("std");
const format = @import("format.zig");
const Tree = @import("Tree.zig");
const queue = @import("queue.zig");

const Allocator = std.mem.Allocator;
const Mutex = std.Io.Mutex;

const ScanEngine = @This();

pub const EntryId = Tree.EntryId;

/// Options for the text dump produced by dump().
pub const DumpOptions = struct {
    /// Maximum tree depth to print (root is depth 0).
    max_depth: u32 = std.math.maxInt(u32),
    /// Skip directories smaller than this many bytes.
    min_size: u64 = 0,
};

pub const MountStats = struct {
    /// Total size of partition
    total: u64,

    /// Available space on partition
    available: u64,

    /// Reserved space for root
    reserved: u64,

    /// Whether info was requested for mount point (true)
    /// or for some directory inside mount point
    is_mount_point: bool,
};

pub const ScanStats = struct {
    total_dirs: u32,
    total_files: u32,
    scanned_size: u64,
    current_dir_size: u64,
    unknown_size: u64,
    available_size: u64,
    is_mount_point: bool,
};

/// One entry of a directory listing on disk, as produced by the caller.
pub const DirEntry = struct {
    name: []const u8,
    size: u64,
    kind: Kind,
    can_scan: bool = false,

    pub const Kind = enum {
        directory,
        file,
        sym_link,
    };
};

pub const ListDirEntry = struct {
    id: ?EntryId,
    name: []const u8,
    size: u64,
    kind: Kind,

    pub const Kind = enum {
        parent,
        directory,
        file,
        sym_link,
    };

    fn lessThan(_: void, a: ListDirEntry, b: ListDirEntry) bool {
        if (a.kind == .parent and b.kind != .parent) {
            return true;
        } else if (b.kind == .parent) {
            return false;
        }
        if (a.size != b.size) {
            return a.size > b.size;
        } else {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }
};

/// `rescan_existing` additionally re-queues the subdirectories the tree
/// already knows.
pub const ScanJob = struct {
    id: EntryId,
    rescan_existing: bool = false,
};

/// Files are not tree nodes, so they are addressed by parent and name;
/// the queue entry owns the name until the job pops.
pub const FileJob = struct {
    parent: EntryId,
    name: []const u8,
};

/// One unit of worker work. Every variant starts by resolving its
/// directory from the tree and taking a fresh listing of it.
pub const Job = union(enum) {
    scan: ScanJob,
    /// Deletes the directory in rounds: each round removes what it can,
    /// queues jobs for what survives, and updates the tree; the
    /// directory itself goes once nothing is left.
    delete_dir: EntryId,
    delete_file: FileJob,
};

_mutex: Mutex = .init,
_io: std.Io,
_tree: Tree,
/// Owned copy of the scanned root path
_scanned_path: []const u8,

/// Worker-generated work: first scans, rescans of new dirs, follow-up
/// deletion rounds. Push order is load-bearing — see pushJobs.
_work_stack: std.ArrayList(Job) = .empty,
user_job_queue: queue.Queue(Job, 16) = .{},
/// The job returned by the last nextJob call, consumed by applyListing
_in_flight: ?Job = null,

/// Single-slot delete failure for the UI; fixed-size so recording never
/// allocates.
_last_error_buf: [256]u8 = undefined,
_last_error_len: u16 = 0,

/// Incremented on every transition to idle (queue drained or stop
/// requested); idle-waiters park on it, so the wait survives repeated
/// scans instead of firing only once.
_idle_epoch: std.atomic.Value(u32) = .init(0),

_should_stop: bool = false,
_is_scanning: bool = false,
_has_changes: bool = false,

total_dirs: u32 = 0,
total_files: u32 = 0,
scanned_size: u64 = 0,
currently_scanned_id: EntryId = .root,

pub fn init(allocator: Allocator, io: std.Io, scanned_path: []const u8) !ScanEngine {
    const path = try allocator.dupe(u8, scanned_path);
    errdefer allocator.free(path);
    var tree = try Tree.init(allocator, path);
    errdefer tree.deinit(allocator);

    var engine = ScanEngine{
        ._io = io,
        ._tree = tree,
        ._scanned_path = path,
        ._is_scanning = true,
    };
    try engine._work_stack.append(allocator, .{ .scan = .{ .id = .root } });
    return engine;
}

pub fn deinit(self: *ScanEngine, allocator: Allocator) void {
    // queued delete_file jobs still own their names; popped ones
    // belong to the worker
    while (self.user_job_queue.popBack()) |job| {
        if (job == .delete_file) allocator.free(job.delete_file.name);
    }
    self._tree.deinit(allocator);
    allocator.free(self._scanned_path);
    self._work_stack.deinit(allocator);
}

pub fn scannedPath(self: *ScanEngine) []const u8 {
    return self._scanned_path;
}

pub fn requestStop(self: *ScanEngine) void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    self._should_stop = true;
}

pub fn stopRequested(self: *ScanEngine) bool {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    return self._should_stop;
}

/// Transitions to idle and wakes idle-waiters. No-op when already idle.
/// Caller must hold `_mutex`.
fn setIdleLocked(self: *ScanEngine) void {
    if (!self._is_scanning) return;
    self._is_scanning = false;
    _ = self._idle_epoch.fetchAdd(1, .release);
    self._io.futexWake(u32, &self._idle_epoch.raw, std.math.maxInt(u32));
}

/// Clears the scanning flag; called by the runtime worker when it exits.
pub fn markIdle(self: *ScanEngine) void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    self.setIdleLocked();
}

pub fn isScanning(self: *ScanEngine) bool {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    return self._is_scanning;
}

/// Returns and clears the pending-changes flag.
pub fn hasChanges(self: *ScanEngine) bool {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    const had = self._has_changes;
    self._has_changes = false;
    return had;
}

/// Returns null when both queues are drained or a stop was requested.
/// Ownership of a popped `delete_file` name moves to the caller, which
/// must free it with the same allocator.
pub fn nextJob(self: *ScanEngine, allocator: Allocator) ?Job {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    if (self._should_stop) {
        self.setIdleLocked();
        return null;
    }
    while (true) {
        const job: Job = blk: {
            if (self.user_job_queue.popBack()) |user_job| break :blk user_job;
            if (self._work_stack.pop()) |stack_job| break :blk stack_job;
            self.setIdleLocked();
            return null;
        };
        // A rescan may have dropped this entry from the tree after its job
        // was queued; its totals were already folded away by setChildren,
        // so applying another listing would adjust the counters again.
        const target: EntryId = switch (job) {
            .scan => |scan| scan.id,
            .delete_dir => |id| id,
            .delete_file => |file| file.parent,
        };
        if (self.isAttachedLocked(target)) {
            self._in_flight = job;
            self.currently_scanned_id = target;
            self._is_scanning = true;
            return job;
        }
        if (job == .delete_file) allocator.free(job.delete_file.name);
    }
}

/// True when `id` still hangs off the root: setChildren marks the entries
/// it drops, and every descendant of a marked entry is detached with it.
/// Caller must hold `_mutex`.
fn isAttachedLocked(self: *ScanEngine, id: EntryId) bool {
    var current = id;
    while (true) {
        const node = self._tree.getNode(current);
        if (node.removed) return false;
        current = node.parent() orelse return true;
    }
}

/// Blocks until the engine is idle: no listing in flight and no queued work
/// (or a stop was requested). Repeatable — a rescan that drains later is
/// waited out too. Returns immediately when already idle; note this has the
/// same TOCTOU window as `isScanning`: work queued just after the check may
/// be missed. `error.Timeout` when the timeout expires first.
pub fn waitIdle(self: *ScanEngine, io: std.Io, timeout: std.Io.Timeout) (std.Io.Timeout.Error || std.Io.Cancelable)!void {
    const deadline: ?std.Io.Clock.Timestamp = switch (timeout) {
        .none => null,
        .duration => |d| .fromNow(io, d),
        .deadline => |d| d,
    };
    while (true) {
        self._mutex.lockUncancelable(self._io);
        const idle = !self._is_scanning;
        const epoch = self._idle_epoch.raw;
        self._mutex.unlock(self._io);

        if (idle) return;
        if (deadline) |d| {
            if (d.clock.now(io).durationTo(d.raw).nanoseconds <= 0) return error.Timeout;
        }

        const wait: std.Io.Timeout = if (deadline) |d| .{ .deadline = d } else .none;
        io.futexWaitTimeout(u32, &self._idle_epoch.raw, epoch, wait) catch |err| return err;
    }
}

/// Full path of a tree entry, allocated with the given allocator.
pub fn pathOf(self: *ScanEngine, allocator: Allocator, id: EntryId) ![]u8 {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    var path_buf = std.ArrayList(u8).empty;
    errdefer path_buf.deinit(allocator);
    var id_buf = std.ArrayList(EntryId).empty;
    defer id_buf.deinit(allocator);
    try self._tree.computeFullPath(allocator, id, &path_buf, &id_buf);
    return try path_buf.toOwnedSlice(allocator);
}

/// Applies a listing taken by the caller: updates the tree, sizes and
/// counters, and queues newly discovered subdirectories for scanning.
pub fn applyListing(
    self: *ScanEngine,
    allocator: Allocator,
    arena: Allocator,
    id: EntryId,
    entries: []const DirEntry,
) !void {
    var dir_names = std.ArrayList([]const u8).empty;
    defer dir_names.deinit(arena);
    var files_size: u64 = 0;
    var files_count: u32 = 0;
    for (entries) |entry| {
        switch (entry.kind) {
            .directory => if (entry.can_scan) {
                try dir_names.append(arena, entry.name);
            },
            // symlinks count as size-0 files: unlink removes the link,
            // never the target
            .file, .sym_link => {
                files_size += entry.size;
                files_count += 1;
            },
        }
    }

    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    var size_delta: i64 = 0;
    var files_delta: i32 = 0;
    const prev_root = self._tree.getNode(id);
    size_delta -= prev_root.total_size;
    files_delta -= @intCast(prev_root.files);
    const set_children_result = try self._tree.setChildren(
        allocator,
        arena,
        id,
        dir_names.items,
        files_size,
        files_count,
    );
    const new_root = self._tree.getNode(id);
    size_delta += new_root.total_size;
    files_delta += @intCast(new_root.files);

    for (set_children_result.new_dirs) |dir_id| {
        try self._work_stack.append(allocator, .{ .scan = .{ .id = dir_id } });
    }
    if (self._in_flight) |in_flight| {
        if (in_flight == .scan and in_flight.scan.rescan_existing) {
            for (set_children_result.existing_dirs) |dir_id| {
                try self._work_stack.append(allocator, .{ .scan = .{ .id = dir_id, .rescan_existing = true } });
            }
        }
        self._in_flight = null;
    }

    self.total_dirs += @intCast(set_children_result.new_dirs.len);
    self.total_dirs -= set_children_result.removed_dirs;
    self.total_files -= @intCast(set_children_result.removed_files);
    if (size_delta > 0) {
        self.scanned_size += @intCast(size_delta);
    } else if (size_delta < 0) {
        self.scanned_size -= @intCast(-size_delta);
    }
    if (files_delta > 0) {
        self.total_files += @intCast(files_delta);
    } else if (files_delta < 0) {
        self.total_files -= @intCast(-files_delta);
    }
    self._has_changes = true;
}

pub fn getStats(self: *ScanEngine, dir_id: EntryId, mount: ?MountStats) ScanStats {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    const scanned_size = self.scanned_size;
    var stats: ScanStats = .{
        .total_dirs = self.total_dirs,
        .total_files = self.total_files,
        .scanned_size = scanned_size,
        .current_dir_size = scanned_size,
        .unknown_size = 0,
        .available_size = 0,
        .is_mount_point = false,
    };

    const node = self._tree.getNode(dir_id);
    if (node.parent() != null) {
        stats.current_dir_size = @intCast(node.total_size);
    }

    if (mount) |m| {
        stats.unknown_size = m.total -| (m.reserved + m.available + stats.scanned_size);
        stats.available_size = m.available;
        stats.is_mount_point = m.is_mount_point;
    }

    return stats;
}

pub fn getParentId(self: *ScanEngine, id: EntryId) ?EntryId {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    return self._tree.getNode(id).parent();
}

/// Returns the dir currently being scanned if it is inside `parent`.
pub fn getScannedChildId(self: *ScanEngine, parent: EntryId) ?EntryId {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    if (!self._is_scanning) {
        return null;
    }
    var scanned_id = self.currently_scanned_id;
    while (true) {
        const scanned = self._tree.getNode(scanned_id);
        if (scanned.parent()) |scanned_parent| {
            if (scanned_parent.eql(parent)) {
                return scanned_id;
            }
            scanned_id = scanned_parent;
        } else break;
    }
    return null;
}

/// Queues a rescan request coming from user actions. Silently ignored when
/// the bounded queue is full.
pub fn queueUserScan(self: *ScanEngine, id: EntryId, rescan_existing: bool) void {
    _ = self.queueUserJob(.{ .scan = .{ .id = id, .rescan_existing = rescan_existing } }) catch return;
}

fn queueUserJob(self: *ScanEngine, job: Job) Allocator.Error!bool {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    return self.queueUserJobLocked(job);
}

/// Returns false when the bounded queue was full and the job was
/// dropped — tolerable because scans self-heal on the next listing and
/// user deletions are dialog-gated.
fn queueUserJobLocked(self: *ScanEngine, job: Job) Allocator.Error!bool {
    if (self._should_stop) return true;
    // the ring is fixed-size, so full is the only failure
    self.user_job_queue.putBack(job) catch return false;
    // raise the flag so waitIdle covers the queued job
    self._is_scanning = true;
    return true;
}

/// Directories resolve to a delete_dir job (by tree id), everything
/// else to delete_file with a copy of `name`. OOM is the only error;
/// a full user queue drops the job silently.
pub fn requestDelete(self: *ScanEngine, allocator: Allocator, parent: EntryId, name: []const u8) Allocator.Error!void {
    {
        self._mutex.lockUncancelable(self._io);
        defer self._mutex.unlock(self._io);
        if (self.findChildDirLocked(parent, name)) |id| {
            _ = try self.queueUserJobLocked(.{ .delete_dir = id });
            return;
        }
    }
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    if (try self.queueUserJob(.{ .delete_file = .{ .parent = parent, .name = name_copy } })) return;
    // dropped: the queue never took ownership of the copy
    allocator.free(name_copy);
}

/// Appends in order; the stack is LIFO, so with `[resume, child_a,
/// child_b]` the children run before the resume job waiting on them.
pub fn pushJobs(self: *ScanEngine, allocator: Allocator, jobs: []const Job) Allocator.Error!void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    try self._work_stack.appendSlice(allocator, jobs);
}

/// `remaining` is what survived one deletion round inside `id`: updates
/// the tree and queues a resume job for `id` plus a delete job per
/// surviving subdirectory — children empty out before `id` is revisited.
pub fn applyDeleteRound(
    self: *ScanEngine,
    allocator: Allocator,
    arena: Allocator,
    id: EntryId,
    remaining: []const DirEntry,
) Allocator.Error!void {
    try self.applyListing(allocator, arena, id, remaining);

    var jobs: std.ArrayList(Job) = .empty;
    defer jobs.deinit(allocator);
    try jobs.append(allocator, .{ .delete_dir = id });

    self._mutex.lockUncancelable(self._io);
    for (remaining) |entry| {
        if (entry.kind != .directory) continue;
        const child = self.findChildDirLocked(id, entry.name) orelse continue;
        // OOM here keeps the resume job queued, so the round still
        // converges; the missed child is picked up on the next visit
        jobs.append(allocator, .{ .delete_dir = child }) catch break;
    }
    self._mutex.unlock(self._io);

    try self.pushJobs(allocator, jobs.items);
}

/// Caller must hold `_mutex`.
fn findChildDirLocked(self: *ScanEngine, parent: EntryId, name: []const u8) ?EntryId {
    var child = self._tree.getNode(parent).firstChild();
    while (child) |c| : (child = self._tree.getNode(c).nextNode()) {
        if (std.mem.eql(u8, self._tree.getNodeName(self._tree.getNode(c)), name)) return c;
    }
    return null;
}

/// Single slot for the UI: overwrites any earlier failure. Never allocates.
pub fn recordDeleteError(self: *ScanEngine, name: []const u8, err: anyerror) void {
    var name_buf: [67]u8 = undefined;
    const shown = if (name.len <= name_buf.len - 3)
        name
    else
        std.fmt.bufPrint(&name_buf, "{s}...", .{name[0 .. name_buf.len - 3]}) catch unreachable;

    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    const msg = std.fmt.bufPrint(&self._last_error_buf, "Failed to delete '{s}': {s}", .{ shown, @errorName(err) }) catch {
        // unreachable by construction: the name is capped and error names
        // are far shorter than the remaining space
        self._last_error_len = 0;
        return;
    };
    self._last_error_len = @intCast(msg.len);
}

/// Moves the last recorded deletion failure into `buf` (truncated to
/// fit); null when nothing failed since the previous call.
pub fn takeError(self: *ScanEngine, buf: []u8) ?[]const u8 {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    if (self._last_error_len == 0) return null;
    const n = @min(buf.len, self._last_error_len);
    const out = buf[0..n];
    @memcpy(out, self._last_error_buf[0..n]);
    self._last_error_len = 0;
    return out;
}

pub const Counters = struct {
    dirs: u32,
    files: u32,
    scanned_size: u64,
};

/// Snapshot of the progress counters.
pub fn counters(self: *ScanEngine) Counters {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);
    return .{
        .dirs = self.total_dirs,
        .files = self.total_files,
        .scanned_size = self.scanned_size,
    };
}

pub fn deinitListDir(allocator: Allocator, entries: *std.ArrayList(ListDirEntry)) void {
    for (entries.items) |entry| {
        allocator.free(entry.name);
    }
    entries.clearAndFree(allocator);
}

/// Prints the tree: one line per directory, size right-aligned in a
/// column, nested with box-drawing glyphs in name order. Files are not
/// stored in the tree and are not printed.
pub fn dump(
    self: *ScanEngine,
    allocator: Allocator,
    writer: *std.Io.Writer,
    opts: DumpOptions,
) !void {
    self._mutex.lockUncancelable(self._io);
    defer self._mutex.unlock(self._io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var width: usize = 0;
    try self.measureDumpWidth(arena.allocator(), .root, 0, opts, &width);

    const root = self._tree.getNode(.root);
    const size_str = try sizeLabel(arena.allocator(), root.total_size);
    try writer.print("{s: >[2]}  {s}/\n", .{ size_str, self._scanned_path, width });

    try self.dumpRec(arena.allocator(), writer, .root, "", 0, opts, width);
}

fn measureDumpWidth(
    self: *ScanEngine,
    arena: Allocator,
    id: EntryId,
    depth: u32,
    opts: DumpOptions,
    width: *usize,
) !void {
    const node = self._tree.getNode(id);
    const size_str = try sizeLabel(arena, node.total_size);
    if (size_str.len > width.*) {
        width.* = size_str.len;
    }
    if (depth >= opts.max_depth) {
        return;
    }
    var child = node.firstChild();
    while (child) |child_id| {
        const child_node = self._tree.getNode(child_id);
        if (child_node.total_size >= opts.min_size) {
            try self.measureDumpWidth(arena, child_id, depth + 1, opts, width);
        }
        child = child_node.nextNode();
    }
}

fn dumpRec(
    self: *ScanEngine,
    arena: Allocator,
    writer: *std.Io.Writer,
    id: EntryId,
    prefix: []const u8,
    depth: u32,
    opts: DumpOptions,
    width: usize,
) !void {
    const node = self._tree.getNode(id);
    var child = node.firstChild();
    while (child) |child_id| {
        const child_node = self._tree.getNode(child_id);
        const is_last = child_node.nextNode() == null;
        if (depth + 1 <= opts.max_depth and child_node.total_size >= opts.min_size) {
            const size_str = try sizeLabel(arena, child_node.total_size);
            const glyph: []const u8 = if (is_last) "└── " else "├── ";
            try writer.print("{s: >[4]}  {s}{s}{s}/\n", .{
                size_str, prefix, glyph, self._tree.getNodeName(child_node), width,
            });
            if (depth + 1 < opts.max_depth) {
                const child_prefix = try std.mem.concat(arena, u8, &.{
                    prefix,
                    if (is_last) "    " else "│   ",
                });
                try self.dumpRec(arena, writer, child_id, child_prefix, depth + 1, opts, width);
            }
        }
        child = child_node.nextNode();
    }
}

fn sizeLabel(arena: Allocator, size: i64) ![]const u8 {
    const padded = try format.formatSize(arena, @intCast(@max(0, size)), 0);
    return std.mem.trimEnd(u8, padded, " ");
}

/// Merges tree children with a fresh listing taken by the caller; queues a
/// rescan when the fresh listing disagrees with the tree.
pub fn listDirMerged(
    self: *ScanEngine,
    allocator: Allocator,
    arena: Allocator,
    dir_id: EntryId,
    fresh_entries: []const DirEntry,
) !std.ArrayList(ListDirEntry) {
    var root_children = std.ArrayList(ListDirEntry).empty;
    errdefer deinitListDir(allocator, &root_children);

    var dir_entry: Tree.DirEntry = undefined;
    var dir_path: []const u8 = "";

    {
        self._mutex.lockUncancelable(self._io);
        defer self._mutex.unlock(self._io);

        const root = self._tree.getNode(dir_id);
        if (root.parent()) |parent| {
            try root_children.append(allocator, .{
                .id = parent,
                .name = try allocator.dupe(u8, ".."),
                .size = 0,
                .kind = .parent,
            });
        } else {
            try root_children.append(allocator, .{
                .id = .root,
                .name = try allocator.dupe(u8, "."),
                .size = 0,
                .kind = .parent,
            });
        }

        if (root.firstChild()) |first| {
            var current = first;
            while (true) {
                const entry = self._tree.getNode(current);
                const size: u64 = if (entry.total_size >= 0) @intCast(entry.total_size) else 0;
                try root_children.append(allocator, .{
                    .id = current,
                    .name = try allocator.dupe(u8, self._tree.getNodeName(entry)),
                    .size = size,
                    .kind = .directory,
                });
                current = entry.nextNode() orelse break;
            }
        }

        dir_entry = root;

        var path_buf = std.ArrayList(u8).empty;
        var id_buf = std.ArrayList(EntryId).empty;
        try self._tree.computeFullPath(arena, dir_id, &path_buf, &id_buf);
        dir_path = try arena.dupe(u8, path_buf.items);
    }

    if (dir_path.len == 0) {
        std.mem.sort(ListDirEntry, root_children.items, {}, ListDirEntry.lessThan);
        return root_children;
    }

    var dirs_current_size: i64 = 0;
    for (root_children.items) |*item| {
        dirs_current_size += @intCast(item.size);
    }
    const dirs_current: u32 = @intCast(root_children.items.len -| 1);

    var need_rescan = false;
    var dirs_matched: u32 = 0;
    var files_actual: u32 = 0;
    var files_actual_size: i64 = 0;
    for (fresh_entries) |entry| {
        switch (entry.kind) {
            .directory => {
                for (root_children.items) |*item| {
                    if (std.mem.eql(u8, item.name, entry.name)) {
                        if (item.kind == .directory) {
                            dirs_matched += 1;
                        } else {
                            need_rescan = true;
                        }
                        break;
                    }
                } else {
                    try root_children.append(allocator, .{
                        .id = null,
                        .name = try allocator.dupe(u8, entry.name),
                        .size = 0,
                        .kind = .directory,
                    });
                    if (entry.can_scan) {
                        need_rescan = true;
                    }
                }
            },
            .file => {
                files_actual += 1;
                files_actual_size += @intCast(entry.size);
                try root_children.append(allocator, .{
                    .id = null,
                    .name = try allocator.dupe(u8, entry.name),
                    .size = entry.size,
                    .kind = .file,
                });
            },
            .sym_link => {
                files_actual += 1;
                try root_children.append(allocator, .{
                    .id = null,
                    .name = try allocator.dupe(u8, entry.name),
                    .size = 0,
                    .kind = .sym_link,
                });
            },
        }
    }

    need_rescan |= files_actual != dir_entry.files;
    need_rescan |= files_actual_size != (dir_entry.total_size - dirs_current_size);
    need_rescan |= dirs_current != dirs_matched;

    if (need_rescan) {
        std.log.info("rescanning {s}", .{dir_path});
        self.queueUserScan(dir_id, false);
    }

    std.mem.sort(ListDirEntry, root_children.items, {}, ListDirEntry.lessThan);
    return root_children;
}

const zero_wait: std.Io.Timeout = .{ .duration = .{ .raw = .zero, .clock = .awake } };

test "waitIdle re-arms across repeated scans" {
    const gpa = std.testing.allocator;
    var engine = try ScanEngine.init(gpa, std.testing.io, "base");
    defer engine.deinit(gpa);

    // scanning: even a zero timeout must not report idle
    try std.testing.expectError(error.Timeout, engine.waitIdle(std.testing.io, zero_wait));

    const root_job = engine.nextJob(gpa).?;
    try std.testing.expect(root_job == .scan);
    try std.testing.expectError(error.Timeout, engine.waitIdle(std.testing.io, zero_wait));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try engine.applyListing(gpa, arena.allocator(), root_job.scan.id, &.{});
    try std.testing.expectError(error.Timeout, engine.waitIdle(std.testing.io, zero_wait));

    // the listing is consumed and nothing is queued: first idle
    try std.testing.expect(engine.nextJob(gpa) == null);
    try engine.waitIdle(std.testing.io, zero_wait);

    // a rescan after the first completion re-arms the wait
    engine.queueUserScan(.root, false);
    const rescanned = engine.nextJob(gpa).?;
    try std.testing.expectError(error.Timeout, engine.waitIdle(std.testing.io, zero_wait));

    try engine.applyListing(gpa, arena.allocator(), rescanned.scan.id, &.{});
    try std.testing.expect(engine.nextJob(gpa) == null);
    try engine.waitIdle(std.testing.io, zero_wait);
}

test "queued work under an entry detached by a rescan is skipped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var engine = try ScanEngine.init(gpa, io, "/base");
    defer engine.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const Subdir = struct {
        fn entry(name: []const u8) DirEntry {
            return .{ .name = name, .size = 0, .kind = .directory, .can_scan = true };
        }
    };

    const root_id = engine.nextJob(gpa).?.scan.id;
    try engine.applyListing(gpa, arena.allocator(), root_id, &.{ Subdir.entry("a"), Subdir.entry("b") });
    // drain the first-scan queue of the two leaves
    while (engine.nextJob(gpa)) |job| {
        try engine.applyListing(gpa, arena.allocator(), job.scan.id, &.{});
    }

    var entries = try engine.listDirMerged(gpa, arena.allocator(), .root, &.{ Subdir.entry("a"), Subdir.entry("b") });
    defer deinitListDir(gpa, &entries);
    const b_id = for (entries.items) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.name, "b")) break entry.id.?;
    } else return error.MissingDir;

    engine.queueUserScan(.root, false);
    const rescanned_id = engine.nextJob(gpa).?.scan.id;
    try engine.applyListing(gpa, arena.allocator(), rescanned_id, &.{Subdir.entry("a")});

    // work queued under the detached b/ must be discarded, not applied:
    // b's totals were already folded away and a second listing would
    // adjust the global counters again
    engine.queueUserScan(b_id, false);
    try std.testing.expect(engine.nextJob(gpa) == null);

    try engine.requestDelete(gpa, b_id, "gone.bin");
    try std.testing.expect(engine.nextJob(gpa) == null);

    // counters still reflect exactly one directory (a/)
    const c = engine.counters();
    try std.testing.expectEqual(@as(u32, 1), c.dirs);
    try std.testing.expectEqual(@as(u64, 0), c.scanned_size);
}
