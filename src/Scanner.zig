const std = @import("std");
const platform = @import("platform.zig");
const Tree = @import("Tree.zig");

const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const AtomicBool = std.atomic.Value(bool);
const AtomicU32 = std.atomic.Value(u32);
const AtomicU64 = std.atomic.Value(u64);
const Scanner = @This();

_state: *CommonState,
_thread: std.Thread,

pub const ScanStats = struct {
    total_dirs: u32,
    total_files: u32,
    scanned_size: u64,
    current_dir_size: u64,
    unknown_size: u64,
    available_size: u64,
    is_mount_point: bool,
};

pub fn init(allocator: Allocator, scanned_path: []const u8) !Scanner {
    const state = try allocator.create(CommonState);
    errdefer allocator.destroy(state);
    state.* = try CommonState.init(allocator, scanned_path);
    errdefer state.deinit(allocator);

    state._is_scanning.store(true, .seq_cst);

    const thread = try std.Thread.spawn(.{}, workerFunc, .{ state, allocator });

    return .{
        ._state = state,
        ._thread = thread,
    };
}

pub fn deinit(self: *Scanner, allocator: Allocator) void {
    self._state._should_stop.store(true, .seq_cst);
    self._thread.join();

    self._state.deinit(allocator);
    allocator.destroy(self._state);
}

pub fn getStats(self: *Scanner, allocator: Allocator, dir_id: Tree.EntryId) !ScanStats {
    const scanned_size = self._state.scanned_size.load(.seq_cst);

    var stats: ScanStats = .{
        .total_dirs = self._state.total_dirs.load(.seq_cst),
        .total_files = self._state.total_files.load(.seq_cst),
        .scanned_size = scanned_size,
        .current_dir_size = scanned_size,
        .unknown_size = 0,
        .available_size = 0,
        .is_mount_point = false,
    };

    if (self._state._tree.getNode(dir_id)) |n| {
        if (n.parent() != null) {
            stats.current_dir_size = @intCast(n.total_size);
        }
    }

    const maybe_mount_stats = try platform.getMountStats(allocator, self._state._scanned_path);

    if (maybe_mount_stats) |mount_stats| {
        stats.unknown_size = mount_stats.total -| (mount_stats.reserved + mount_stats.available + stats.scanned_size);
        stats.available_size = mount_stats.available;
        stats.is_mount_point = mount_stats.is_mount_point;
    }

    return stats;
}

pub fn getParentId(self: *Scanner, element_id: Tree.EntryId) ?Tree.EntryId {
    self._state._mutex.lock();
    defer self._state._mutex.unlock();

    if (self._state._tree.getNode(element_id)) |elem| {
        return elem.parent();
    }
    return null;
}

pub fn isScanning(self: Scanner) bool {
    return self._state._is_scanning.load(.seq_cst);
}

pub fn hasChanges(self: Scanner) bool {
    return self._state._has_changes.swap(false, .seq_cst);
}

pub fn getEntryPath(self: *Scanner, allocator: Allocator, entry: Tree.EntryId) ![]const u8 {
    var path_buf = std.ArrayList(u8).empty;
    errdefer path_buf.deinit(allocator);
    self._state._mutex.lock();
    defer self._state._mutex.unlock();

    var id_buf = std.ArrayList(Tree.EntryId).empty;
    defer id_buf.deinit(allocator);
    try self._state._tree.computeFullPath(allocator, entry, &path_buf, &id_buf);

    return try path_buf.toOwnedSlice(allocator);
}

pub fn getScannedChildId(self: *Scanner, parent: Tree.EntryId) ?Tree.EntryId {
    if (!self._state._is_scanning.load(.seq_cst)) {
        return null;
    }
    var scanned_id = self._state.currently_scanned_id.load(.seq_cst);

    self._state._mutex.lock();
    defer self._state._mutex.unlock();
    while (self._state._tree.getNode(scanned_id)) |scanned| {
        if (scanned.parent()) |scanned_parent| {
            if (scanned_parent.eql(parent)) {
                return scanned_id;
            }
            scanned_id = scanned_parent;
        } else break;
    }
    return null;
}

pub fn deinitListDir(allocator: Allocator, entries: *std.ArrayList(ListDirEntry)) void {
    for (entries.items) |entry| {
        allocator.free(entry.name);
    }
    entries.clearAndFree(allocator);
}

pub fn listDir(self: *Scanner, allocator: Allocator, dir_id: Tree.EntryId) !std.ArrayList(ListDirEntry) {
    var root_children = std.ArrayList(ListDirEntry).empty;
    defer {
        std.mem.sort(ListDirEntry, root_children.items, {}, ListDirEntry.lessThan);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var path_buf = std.ArrayList(u8).empty;
    {
        self._state._mutex.lock();
        defer self._state._mutex.unlock();

        if (self._state._tree.getNode(dir_id)) |root| {
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

                while (self._state._tree.getNode(current)) |entry| {
                    try root_children.append(allocator, .{
                        .id = current,
                        .name = try allocator.dupe(u8, self._state._tree.getNodeName(entry)),
                        .size = if (entry.total_size >= 0) @intCast(entry.total_size) else 0,
                        .kind = .directory,
                    });

                    current = entry.nextNode() orelse break;
                }
            }
        }

        var id_buf = std.ArrayList(Tree.EntryId).empty;
        try self._state._tree.computeFullPath(arena.allocator(), dir_id, &path_buf, &id_buf);
    }

    if (path_buf.items.len == 0) {
        return root_children;
    }

    const dir_path = path_buf.items;
    const entries = try scanSingleDir(arena.allocator(), dir_path);

    //TODO check tree content match actual FS content
    // so rescan is triggered on mismatch
    for (entries) |entry| {
        switch (entry.kind) {
            .file => {
                try root_children.append(allocator, .{
                    .id = null,
                    .name = try allocator.dupe(u8, entry.name),
                    .size = entry.size,
                    .kind = .file,
                });
            },
            else => {},
        }
    }

    return root_children;
}

pub const ListDirEntry = struct {
    id: ?Tree.EntryId,
    name: []const u8,
    size: u64,
    kind: Kind,

    pub const Kind = enum {
        parent,
        directory,
        file,
    };

    fn lessThan(_: void, a: ListDirEntry, b: ListDirEntry) bool {
        if (a.kind == .parent) {
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

const CommonState = struct {
    _tree: Tree,
    _mutex: Mutex,
    _should_stop: AtomicBool,
    _has_changes: AtomicBool,
    _is_scanning: AtomicBool,
    _scanned_path: []const u8,
    total_dirs: AtomicU32,
    total_files: AtomicU32,
    scanned_size: AtomicU64,
    currently_scanned_id: std.atomic.Value(Tree.EntryId),

    fn init(allocator: Allocator, scanned_path: []const u8) !CommonState {
        return .{
            ._tree = try Tree.init(allocator, scanned_path),
            ._mutex = .{},
            ._should_stop = .init(false),
            ._has_changes = .init(false),
            ._is_scanning = .init(false),
            ._scanned_path = scanned_path,
            .total_dirs = .init(0),
            .total_files = .init(0),
            .scanned_size = .init(0),
            .currently_scanned_id = .init(.root),
        };
    }

    pub fn deinit(self: *CommonState, allocator: Allocator) void {
        self._tree.deinit(allocator);
    }
};

fn workerFunc(state: *CommonState, allocator: Allocator) void {
    workerFuncErr(state, allocator) catch |err| {
        std.log.err("Error: {any}", .{err});
    };
    state._is_scanning.store(false, .seq_cst);
}

fn workerFuncErr(state: *CommonState, allocator: Allocator) !void {
    const scan_start_time = std.time.milliTimestamp();

    const QueueItem = struct {
        id: Tree.EntryId,
    };

    var queue = std.ArrayList(QueueItem).empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, .{
        .id = .root,
    });

    var next_print: u32 = 0;

    var path_buf = std.ArrayList(u8).empty;
    defer path_buf.deinit(allocator);

    var path_id_buf = std.ArrayList(Tree.EntryId).empty;
    defer path_id_buf.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    while (queue.pop()) |item| {
        defer _ = arena.reset(.retain_capacity);
        if (state._should_stop.load(.seq_cst)) {
            std.log.info("stop due to stop signal", .{});
            break;
        }
        state.currently_scanned_id.store(item.id, .seq_cst);

        {
            state._mutex.lock();
            defer state._mutex.unlock();
            try state._tree.computeFullPath(allocator, item.id, &path_buf, &path_id_buf);
        }

        const dir_path = path_buf.items;
        const entries = try scanSingleDir(arena.allocator(), dir_path);

        {
            state._mutex.lock();
            defer state._mutex.unlock();

            var files_size: u64 = 0;
            for (entries) |entry| {
                switch (entry.kind) {
                    .directory => {
                        const child_id = blk: {
                            break :blk try state._tree.addNode(allocator, .{
                                .name = entry.name,
                                .parent = item.id,
                            });
                        };

                        _ = state.total_dirs.fetchAdd(1, .seq_cst);
                        try queue.append(allocator, .{
                            .id = child_id,
                        });
                    },
                    .file => {
                        _ = state.total_files.fetchAdd(1, .seq_cst);
                        files_size += entry.size;
                    },
                }
            }
            if (files_size > 0) {
                _ = state.scanned_size.fetchAdd(files_size, .seq_cst);
                state._tree.addSize(item.id, @intCast(files_size));
            }
            state._has_changes.store(true, .seq_cst);
        }

        if (state.total_files.load(.seq_cst) > next_print) {
            next_print += 100_000;
            std.log.info("Dirs: {d}. Files: {d}. Size: {d}", .{
                state.total_dirs.load(.seq_cst),
                state.total_files.load(.seq_cst),
                state.scanned_size.load(.seq_cst),
            });
        }
    }
    const scan_millis: f64 = @floatFromInt(std.time.milliTimestamp() - scan_start_time);

    std.log.info(
        "Scan finished in {d:.2}s. Dirs: {d}. Files: {d}. Size: {d}",
        .{
            scan_millis / 1000,
            state.total_dirs.load(.seq_cst),
            state.total_files.load(.seq_cst),
            state.scanned_size.load(.seq_cst),
        },
    );
}

const DirElement = struct {
    name: []const u8,
    size: u64,
    kind: Kind,

    pub const Kind = enum {
        directory,
        file,
    };
};

fn scanSingleDir(arena: Allocator, dir_path: []const u8) ![]DirElement {
    var entries = std.ArrayList(DirElement).empty;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Failed to open `{s}`: {any}", .{ dir_path, err });
        return entries.items;
    };
    defer dir.close();

    var it = dir.iterateAssumeFirstIteration();
    while (it.next()) |maybe_entry| {
        const entry = maybe_entry orelse break;
        const name = try arena.dupe(u8, entry.name);
        switch (entry.kind) {
            .directory => {
                try entries.append(arena, .{
                    .name = name,
                    .size = 0,
                    .kind = .directory,
                });
            },
            .file => {
                const stats = dir.statFile(entry.name) catch |err| {
                    std.log.warn("Failed to stat file `{s}/{s}`: {any}", .{ dir_path, entry.name, err });
                    continue;
                };
                try entries.append(arena, .{
                    .name = name,
                    .size = stats.size,
                    .kind = .file,
                });
            },
            else => {},
        }
    } else |err| {
        std.log.warn("Failed to iterate in `{s}`: {any}", .{ dir_path, err });
    }

    return entries.items;
}
