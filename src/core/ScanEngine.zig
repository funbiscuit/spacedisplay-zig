//! Pure scan state machine: owns the tree, scan queues and counters. The
//! caller pops a queued dir with nextDirToScan, lists it on disk, and feeds
//! the listing back through applyListing. Mutex-guarded, thread-safe.

const std = @import("std");
const format = @import("format.zig");
const Tree = @import("Tree.zig");
const queue = @import("queue.zig");

const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

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

const QueueItem = struct {
    id: EntryId,
    rescan_existing: bool,
};

_mutex: Mutex = .{},
_tree: Tree,
/// Owned copy of the scanned root path
_scanned_path: []const u8,

/// Directories pending their first scan
_scan_stack: std.ArrayList(QueueItem) = .empty,
/// Rescan requests coming from user actions in the UI
user_scan_queue: queue.Queue(QueueItem, 16) = .{},
/// The item returned by the last nextDirToScan call, consumed by applyListing
_in_flight: ?QueueItem = null,

_should_stop: bool = false,
_is_scanning: bool = false,
_has_changes: bool = false,

total_dirs: u32 = 0,
total_files: u32 = 0,
scanned_size: u64 = 0,
currently_scanned_id: EntryId = .root,

pub fn init(allocator: Allocator, scanned_path: []const u8) !ScanEngine {
    const path = try allocator.dupe(u8, scanned_path);
    errdefer allocator.free(path);
    var tree = try Tree.init(allocator, path);
    errdefer tree.deinit(allocator);

    var engine = ScanEngine{
        ._tree = tree,
        ._scanned_path = path,
        ._is_scanning = true,
    };
    try engine._scan_stack.append(allocator, .{ .id = .root, .rescan_existing = false });
    return engine;
}

pub fn deinit(self: *ScanEngine, allocator: Allocator) void {
    self._tree.deinit(allocator);
    allocator.free(self._scanned_path);
    self._scan_stack.deinit(allocator);
}

pub fn scannedPath(self: *ScanEngine) []const u8 {
    return self._scanned_path;
}

pub fn requestStop(self: *ScanEngine) void {
    self._mutex.lock();
    defer self._mutex.unlock();
    self._should_stop = true;
}

pub fn stopRequested(self: *ScanEngine) bool {
    self._mutex.lock();
    defer self._mutex.unlock();
    return self._should_stop;
}

/// Clears the scanning flag; called by the runtime worker when it exits.
pub fn markIdle(self: *ScanEngine) void {
    self._mutex.lock();
    defer self._mutex.unlock();
    self._is_scanning = false;
}

pub fn isScanning(self: *ScanEngine) bool {
    self._mutex.lock();
    defer self._mutex.unlock();
    return self._is_scanning;
}

/// Returns and clears the pending-changes flag.
pub fn hasChanges(self: *ScanEngine) bool {
    self._mutex.lock();
    defer self._mutex.unlock();
    const had = self._has_changes;
    self._has_changes = false;
    return had;
}

/// Pops the next directory to scan (user rescans first). Returns null when
/// the queue is drained or a stop was requested.
pub fn nextDirToScan(self: *ScanEngine) ?EntryId {
    self._mutex.lock();
    defer self._mutex.unlock();

    if (self._should_stop) {
        self._is_scanning = false;
        return null;
    }
    const item: QueueItem = blk: {
        if (self.user_scan_queue.popBack()) |user_item| break :blk user_item;
        if (self._scan_stack.pop()) |stack_item| break :blk stack_item;
        self._is_scanning = false;
        return null;
    };
    self._in_flight = item;
    self.currently_scanned_id = item.id;
    self._is_scanning = true;
    return item.id;
}

/// Full path of a tree entry, allocated with the given allocator.
pub fn pathOf(self: *ScanEngine, allocator: Allocator, id: EntryId) ![]u8 {
    self._mutex.lock();
    defer self._mutex.unlock();

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
            .file => {
                files_size += entry.size;
                files_count += 1;
            },
        }
    }

    self._mutex.lock();
    defer self._mutex.unlock();

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
        try self._scan_stack.append(allocator, .{ .id = dir_id, .rescan_existing = false });
    }
    if (self._in_flight) |in_flight| {
        if (in_flight.rescan_existing) {
            for (set_children_result.existing_dirs) |dir_id| {
                try self._scan_stack.append(allocator, .{ .id = dir_id, .rescan_existing = true });
            }
        }
        self._in_flight = null;
    }

    self.total_dirs += @intCast(set_children_result.new_dirs.len);
    self.total_dirs -= set_children_result.removed_dirs;
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
    self._mutex.lock();
    defer self._mutex.unlock();

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
    self._mutex.lock();
    defer self._mutex.unlock();
    return self._tree.getNode(id).parent();
}

/// Returns the dir currently being scanned if it is inside `parent`.
pub fn getScannedChildId(self: *ScanEngine, parent: EntryId) ?EntryId {
    self._mutex.lock();
    defer self._mutex.unlock();

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
    self.user_scan_queue.putBack(.{ .id = id, .rescan_existing = rescan_existing }) catch {};
}

pub const Counters = struct {
    dirs: u32,
    files: u32,
    scanned_size: u64,
};

/// Snapshot of the progress counters.
pub fn counters(self: *ScanEngine) Counters {
    self._mutex.lock();
    defer self._mutex.unlock();
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
    self._mutex.lock();
    defer self._mutex.unlock();

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
                    prefix, if (is_last) "    " else "│   ",
                });
                try self.dumpRec(arena, writer, child_id, child_prefix, depth + 1, opts, width);
            }
        }
        child = child_node.nextNode();
    }
}

fn sizeLabel(arena: Allocator, size: i64) ![]const u8 {
    const padded = try format.formatSize(arena, @intCast(@max(0, size)), 0);
    return std.mem.trimRight(u8, padded, " ");
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
        self._mutex.lock();
        defer self._mutex.unlock();

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
