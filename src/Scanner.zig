const std = @import("std");
const clap = @import("clap");

const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const AtomicBool = std.atomic.Value(bool);
const Scanner = @This();

_state: *CommonState,
_thread: std.Thread,

pub fn init(allocator: Allocator, scanned_path: []const u8) !Scanner {
    const state = try allocator.create(CommonState);
    errdefer allocator.destroy(state);
    state.* = CommonState.init(scanned_path);

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

pub fn getParentId(self: *Scanner, element_id: ?u32) ?u32 {
    if (element_id) |id| {
        self._state._mutex.lock();
        defer self._state._mutex.unlock();

        if (self._state._tree.get_node(id)) |elem| {
            if (elem.parent > 0) {
                return elem.parent;
            }
        }
    }
    return null;
}

pub fn isScanning(self: Scanner) bool {
    return self._state._is_scanning.load(.seq_cst);
}

pub fn hasChanges(self: Scanner) bool {
    return self._state._has_changes.swap(false, .seq_cst);
}

pub fn getEntryPath(self: *Scanner, allocator: Allocator, entry: ?u32) ![]const u8 {
    const dir_id = entry orelse 1;

    var path_buf = std.ArrayList(u8).empty;
    errdefer path_buf.deinit(allocator);
    self._state._mutex.lock();
    defer self._state._mutex.unlock();

    var index_buf = std.ArrayList(u32).empty;
    defer index_buf.deinit(allocator);
    try self._state._tree.computeFullPath(allocator, dir_id, &path_buf, &index_buf);

    return try path_buf.toOwnedSlice(allocator);
}

pub fn deinitListDir(allocator: Allocator, entries: *std.ArrayList(ListDirEntry)) void {
    for (entries.items) |entry| {
        allocator.free(entry.name);
    }
    entries.clearAndFree(allocator);
}

pub fn listDir(self: *Scanner, allocator: Allocator, parent: ?u32) !std.ArrayList(ListDirEntry) {
    var root_children = std.ArrayList(ListDirEntry).empty;
    defer {
        std.mem.sort(ListDirEntry, root_children.items, {}, ListDirEntry.lessThan);
    }

    const dir_id = parent orelse 1;
    var path_buf = std.ArrayList(u8).empty;
    defer path_buf.deinit(allocator);
    {
        self._state._mutex.lock();
        defer self._state._mutex.unlock();

        if (self._state._tree.get_node(dir_id)) |root| {
            if (root.parent > 0) {
                try root_children.append(allocator, .{
                    .id = root.parent,
                    .name = try allocator.dupe(u8, ".."),
                    .size = 0,
                    .kind = .parent,
                });
            } else {
                try root_children.append(allocator, .{
                    .id = 1,
                    .name = try allocator.dupe(u8, "."),
                    .size = 0,
                    .kind = .parent,
                });
            }

            var current = root.first_child;
            while (self._state._tree.get_node(current)) |entry| {
                try root_children.append(allocator, .{
                    .id = current,
                    .name = try allocator.dupe(u8, self._state._tree.string_pool.get(entry.name_start, entry.name_len)),
                    .size = if (entry.total_size >= 0) @intCast(entry.total_size) else 0,
                    .kind = .directory,
                });

                current = entry.next_node;
            }
        }

        var index_buf = std.ArrayList(u32).empty;
        defer index_buf.deinit(allocator);
        try self._state._tree.computeFullPath(allocator, dir_id, &path_buf, &index_buf);
    }

    if (path_buf.items.len == 0) {
        return root_children;
    }

    const dir_path = path_buf.items;
    std.log.info("get files in {s}", .{dir_path});
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Failed to open `{s}`: {any}", .{ dir_path, err });
        return root_children;
    };
    defer dir.close();

    //TODO check tree content match actual FS content
    // so rescan is triggered on mismatch
    var it = dir.iterateAssumeFirstIteration();
    while (it.next()) |maybe_entry| {
        const entry = maybe_entry orelse break;
        switch (entry.kind) {
            .file => {
                const stats = dir.statFile(entry.name) catch |err| {
                    std.log.warn("Failed to stat file `{s}/{s}`: {any}", .{ dir_path, entry.name, err });
                    continue;
                };
                try root_children.append(allocator, .{
                    .id = null,
                    .name = try allocator.dupe(u8, entry.name),
                    .size = stats.size,
                    .kind = .file,
                });
            },
            else => {},
        }
    } else |err| {
        std.log.warn("Failed to iterate in `{s}`: {any}", .{ dir_path, err });
    }

    return root_children;
}

pub const ListDirEntry = struct {
    id: ?u32,
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

    fn init(scanned_path: []const u8) CommonState {
        return .{
            ._tree = Tree.init(),
            ._mutex = .{},
            ._should_stop = AtomicBool.init(false),
            ._has_changes = AtomicBool.init(false),
            ._is_scanning = AtomicBool.init(false),
            ._scanned_path = scanned_path,
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
    const root = blk: {
        state._mutex.lock();
        defer state._mutex.unlock();

        break :blk try state._tree.add_node(allocator, .{
            .name = state._scanned_path,
        });
    };

    const QueueItem = struct {
        index: u32,
    };

    var queue = std.ArrayList(QueueItem).empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, .{
        .index = root,
    });

    var dirs: u32 = 0;
    var files: u32 = 0;
    var total_size: u64 = 0;
    var next_print: u32 = 0;

    var path_buf = std.ArrayList(u8).empty;
    defer path_buf.deinit(allocator);

    var path_buf_elems = std.ArrayList(u32).empty;
    defer path_buf_elems.deinit(allocator);

    while (queue.pop()) |item| {
        if (state._should_stop.load(.seq_cst)) {
            std.log.info("stop due to stop signal", .{});
            break;
        }

        {
            state._mutex.lock();
            defer state._mutex.unlock();
            try state._tree.computeFullPath(allocator, item.index, &path_buf, &path_buf_elems);
        }

        const dir_path = path_buf.items;
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            std.log.warn("Failed to open `{s}`: {any}", .{ dir_path, err });
            continue;
        };
        defer dir.close();

        var it = dir.iterateAssumeFirstIteration();
        var files_size: u64 = 0;
        while (it.next()) |maybe_entry| {
            const entry = maybe_entry orelse break;
            switch (entry.kind) {
                .directory => {
                    const child_index = blk: {
                        //TODO don't lock too often
                        state._mutex.lock();
                        defer state._mutex.unlock();
                        defer state._has_changes.store(true, .seq_cst);

                        break :blk try state._tree.add_node(allocator, .{
                            .name = entry.name,
                            .parent = item.index,
                        });
                    };

                    dirs += 1;
                    try queue.append(allocator, .{
                        .index = child_index,
                    });
                },
                .file => {
                    files += 1;
                    const stats = dir.statFile(entry.name) catch |err| {
                        std.log.warn("Failed to stat file `{s}/{s}`: {any}", .{ dir_path, entry.name, err });
                        continue;
                    };
                    total_size += stats.size;
                    files_size += stats.size;
                },
                else => {},
            }
        } else |err| {
            std.log.warn("Failed to iterate in `{s}`: {any}", .{ dir_path, err });
        }
        if (files_size > 0) {
            state._mutex.lock();
            defer state._mutex.unlock();

            state._has_changes.store(true, .seq_cst);
            state._tree.add_size(item.index, @intCast(files_size));
        }
        if (files > next_print) {
            next_print += 100_000;
            std.log.info("Dirs: {d}. Files: {d}. Size: {d}", .{ dirs, files, total_size });
        }
    }
    const scan_millis: f64 = @floatFromInt(std.time.milliTimestamp() - scan_start_time);

    std.log.info(
        "Scan finished in {d:.2}s. Dirs: {d}. Files: {d}. Size: {d}",
        .{ scan_millis / 1000, dirs, files, total_size },
    );
}

fn printTree(tree: Tree, root: u32, indent: usize) void {
    const node = tree.get_node(root) orelse return;

    var buf: [32]u8 = undefined;

    if (indent > buf.len) {
        return;
    }
    if (indent > 0) {
        @memset(buf[0..indent], ' ');
    }

    const name = tree.string_pool.get(node.name_start, node.name_len);
    std.log.info("{s}- {s}: {d}", .{
        buf[0..indent],
        name,
        node.total_size,
    });
    if (node.kind == .directory) {
        var current = node.first_child;
        while (current != 0) {
            const child = tree.get_node(current) orelse continue;
            printTree(tree, current, indent + 2);
            current = child.next_node;
        }
    }
}

pub const Tree = struct {
    nodes: std.ArrayList(DirEntry),
    string_pool: StringPool,

    pub const NewNode = struct {
        name: []const u8,
        parent: u32 = 0,
    };

    pub fn init() Tree {
        return Tree{
            .nodes = std.ArrayList(DirEntry).empty,
            .string_pool = StringPool{},
        };
    }

    pub fn add_size(self: *Tree, dir_index: u32, size: i64) void {
        var current = dir_index;
        while (current != 0) {
            self.nodes.items[current - 1].total_size += size;
            current = self.nodes.items[current - 1].parent;
        }
    }

    pub fn add_node(self: *Tree, allocator: Allocator, node: NewNode) !u32 {
        const name_start = try self.string_pool.add(allocator, node.name);

        var tree_node = DirEntry{
            .name_start = @intCast(name_start),
            .name_len = @intCast(node.name.len),
            .parent = node.parent,
            .total_size = 0,
        };
        const node_index: u32 = @intCast(self.nodes.items.len + 1);

        if (node.parent > 0) {
            //TODO correct sorting
            var parent: *DirEntry = &self.nodes.items[node.parent - 1];
            const prev_first = parent.first_child;
            parent.first_child = node_index;
            tree_node.next_node = prev_first;
        }
        try self.nodes.append(allocator, tree_node);

        return node_index;
    }

    pub fn get_node(self: Tree, index: u32) ?DirEntry {
        if (index == 0 or index > self.nodes.items.len) {
            return null;
        }
        return self.nodes.items[index - 1];
    }

    pub fn computeFullPath(
        self: Tree,
        allocator: Allocator,
        index: u32,
        path_buf: *std.ArrayList(u8),
        index_buf: *std.ArrayList(u32),
    ) !void {
        var total_path_size: usize = 0;
        index_buf.clearRetainingCapacity();
        var current = index;
        while (self.get_node(current)) |node| {
            try index_buf.append(allocator, current);
            if (total_path_size > 0) {
                //separator
                total_path_size += 1;
            }
            total_path_size += node.name_len;
            current = node.parent;
        }
        path_buf.clearRetainingCapacity();
        try path_buf.ensureTotalCapacity(allocator, total_path_size);
        for (0..index_buf.items.len) |idx| {
            const node = self.get_node(index_buf.items[index_buf.items.len - idx - 1]) orelse break;
            const elem_name = self.string_pool.get(node.name_start, node.name_len);
            if (idx > 0) {
                path_buf.appendAssumeCapacity('/');
            }
            path_buf.appendSliceAssumeCapacity(elem_name);
        }
    }

    pub fn deinit(self: *Tree, allocator: Allocator) void {
        self.nodes.deinit(allocator);
        self.string_pool.deinit(allocator);
    }
};

pub const DirEntry = struct {
    name_start: u32,
    name_len: u16,

    first_child: u32 = 0,
    next_node: u32 = 0,
    parent: u32 = 0,

    /// Size of all its children
    total_size: i64,
};

pub const StringPool = struct {
    string_bytes: std.ArrayList(u8) = std.ArrayList(u8).empty,

    pub fn deinit(self: *StringPool, allocator: Allocator) void {
        self.string_bytes.deinit(allocator);
    }

    /// Adds given slice to pool and returns its position in it
    pub fn add(self: *StringPool, allocator: Allocator, slice: []const u8) !usize {
        const index = self.string_bytes.items.len;
        try self.string_bytes.appendSlice(allocator, slice);
        return index;
    }

    pub fn get(self: StringPool, index: usize, len: usize) []const u8 {
        return self.string_bytes.items[index .. index + len];
    }
};

test "add to StringPool" {
    const gpa = std.testing.allocator;
    const initial = [_]u8{ 1, 2, 3 };
    var array = [_]u8{ 1, 2, 3 };

    var pool = StringPool{};
    defer pool.deinit(gpa);

    const index = try pool.add(gpa, &array);
    try std.testing.expectEqualSlices(u8, &initial, pool.get(index, array.len));
    array[0] = 5;
    try std.testing.expectEqualSlices(u8, &initial, pool.get(index, array.len));
}
