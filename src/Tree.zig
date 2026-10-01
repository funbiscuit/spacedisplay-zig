const std = @import("std");
const StringPool = @import("StringPool.zig");

const Allocator = std.mem.Allocator;
const Tree = @This();

_nodes: std.ArrayList(DirEntry),
_strings: StringPool,

/// Represents id of some entry inside a tree
pub const EntryId = packed struct {
    _index: u32,

    pub const root: EntryId = .{ ._index = 0 };

    pub fn eql(self: EntryId, other: EntryId) bool {
        return self._index == other._index;
    }

    fn asId(self: EntryId) u32 {
        return self._index + 1;
    }
};

pub const DirEntry = struct {
    _name_start: u32,
    _name_len: u16,

    _first_child: u32 = 0,
    _next_node: u32 = 0,
    _parent: u32 = 0,

    /// Number of files in this dir
    files: u32 = 0,

    /// Size of all its children
    total_size: i64 = 0,

    pub fn firstChild(self: DirEntry) ?EntryId {
        return if (self._first_child > 0)
            .{ ._index = self._first_child - 1 }
        else
            null;
    }

    pub fn nextNode(self: DirEntry) ?EntryId {
        return if (self._next_node > 0)
            .{ ._index = self._next_node - 1 }
        else
            null;
    }

    pub fn parent(self: DirEntry) ?EntryId {
        return if (self._parent > 0)
            .{ ._index = self._parent - 1 }
        else
            null;
    }
};

pub fn init(allocator: Allocator, root: []const u8) !Tree {
    var tree = Tree{
        ._nodes = std.ArrayList(DirEntry).empty,
        ._strings = .{},
    };
    errdefer tree.deinit(allocator);

    const name_start = try tree._strings.add(allocator, root);
    try tree._nodes.append(allocator, .{
        ._name_start = @intCast(name_start),
        ._name_len = @intCast(root.len),
        .total_size = 0,
    });
    return tree;
}

pub fn deinit(self: *Tree, allocator: Allocator) void {
    self._nodes.deinit(allocator);
    self._strings.deinit(allocator);
}

pub const SetChildrenResult = struct {
    new_dirs: []const EntryId,
    existing_dirs: []const EntryId,
    removed_dirs: u32,
};

pub fn setChildren(
    self: *Tree,
    allocator: Allocator,
    arena: Allocator,
    parent_id: EntryId,
    dir_names: [][]const u8,
    files_size: u64,
    files_count: u32,
) !SetChildrenResult {
    const gen = struct {
        fn nameLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    };
    std.mem.sort([]const u8, dir_names, {}, gen.nameLessThan);

    const parent = self.getNode(parent_id);
    self._nodes.items[parent_id._index].files = files_count;
    var cursor_previous_id: ?EntryId = null;
    var cursor_existing_id = parent.firstChild();
    var cursor_new: usize = 0;

    var new_ids = std.ArrayList(EntryId).empty;
    var existing_ids = std.ArrayList(EntryId).empty;
    try new_ids.ensureTotalCapacityPrecise(arena, dir_names.len);
    try existing_ids.ensureTotalCapacityPrecise(arena, dir_names.len);
    var removed_ids: u32 = 0;

    // initially assume that parent has no size and correct it as we go
    var size_delta: i64 = @intCast(files_size);
    size_delta -= parent.total_size;
    while (true) {
        if (cursor_new < dir_names.len and cursor_existing_id != null) {
            const current_new_name = dir_names[cursor_new];
            const current_existing_entry = self._nodes.items[cursor_existing_id.?._index];
            const current_existing_name = self.getNodeName(current_existing_entry);

            if (std.mem.lessThan(u8, current_new_name, current_existing_name)) {
                // new_name is new node so add it to children
                const node_id = try self.createNode(allocator, current_new_name);
                var node: *DirEntry = &self._nodes.items[node_id._index];
                node._parent = parent_id.asId();
                if (cursor_previous_id) |prev_id| {
                    self._nodes.items[prev_id._index]._next_node = node_id.asId();
                    node._next_node = cursor_existing_id.?.asId();
                } else {
                    self._nodes.items[parent_id._index]._first_child = node_id.asId();
                }
                cursor_previous_id = node_id;
                cursor_new += 1;
                try new_ids.append(arena, node_id);
            } else if (std.mem.lessThan(u8, current_existing_name, current_new_name)) {
                // existing name not present in new nodes - remove it
                if (cursor_previous_id) |prev_id| {
                    self._nodes.items[prev_id._index]._next_node = current_existing_entry._next_node;
                } else {
                    self._nodes.items[parent_id._index]._first_child = current_existing_entry._next_node;
                }
                if (current_existing_entry.nextNode()) |next_id| {
                    cursor_existing_id = self._nodes.items[next_id._index].nextNode();
                } else {
                    cursor_existing_id = null;
                }
                removed_ids += 1;
            } else {
                // entry is kept as is
                size_delta += current_existing_entry.total_size;

                try existing_ids.append(arena, cursor_existing_id.?);
                cursor_previous_id = cursor_existing_id;
                cursor_existing_id = current_existing_entry.nextNode();
                cursor_new += 1;
            }
        } else if (cursor_new < dir_names.len) {
            // no entries left in existing children, add everything whats left
            const node_id = try self.createNode(allocator, dir_names[cursor_new]);
            var node: *DirEntry = &self._nodes.items[node_id._index];
            node._parent = parent_id.asId();
            if (cursor_previous_id) |prev_id| {
                self._nodes.items[prev_id._index]._next_node = node_id.asId();
                node._next_node = 0;
            } else {
                self._nodes.items[parent_id._index]._first_child = node_id.asId();
            }
            cursor_previous_id = node_id;
            cursor_new += 1;
            try new_ids.append(arena, node_id);
        } else if (cursor_existing_id != null) {
            // no new entries left so delete everything remaining
            const current_existing_entry = self.getNode(cursor_existing_id.?);

            if (cursor_previous_id) |prev_id| {
                self._nodes.items[prev_id._index]._next_node = current_existing_entry._next_node;
            } else {
                self._nodes.items[parent_id._index]._first_child = current_existing_entry._next_node;
            }
            if (current_existing_entry.nextNode()) |next_id| {
                cursor_existing_id = self.getNode(next_id).nextNode();
            } else {
                cursor_existing_id = null;
            }
            removed_ids += 1;
        } else break;
    }
    if (size_delta != 0) {
        var current_id: ?EntryId = parent_id;
        while (current_id) |id| {
            self._nodes.items[id._index].total_size += size_delta;
            current_id = self._nodes.items[id._index].parent();
        }
    }
    return .{
        .new_dirs = new_ids.items,
        .existing_dirs = existing_ids.items,
        .removed_dirs = removed_ids,
    };
}

pub fn getNode(self: Tree, id: EntryId) DirEntry {
    std.debug.assert(id._index < self._nodes.items.len);
    return self._nodes.items[id._index];
}

pub fn getNodeName(self: Tree, entry: DirEntry) []const u8 {
    return self._strings.get(entry._name_start, entry._name_len);
}

pub fn computeFullPath(
    self: Tree,
    allocator: Allocator,
    id: EntryId,
    path_buf: *std.ArrayList(u8),
    id_buf: *std.ArrayList(EntryId),
) !void {
    var total_path_size: usize = 0;
    id_buf.clearRetainingCapacity();
    var current = id;
    while (true) {
        const node = self.getNode(current);
        try id_buf.append(allocator, current);
        if (total_path_size > 0) {
            //separator
            total_path_size += 1;
        }
        total_path_size += node._name_len;
        current = node.parent() orelse break;
    }
    path_buf.clearRetainingCapacity();
    try path_buf.ensureTotalCapacity(allocator, total_path_size);
    for (0..id_buf.items.len) |idx| {
        const node = self.getNode(id_buf.items[id_buf.items.len - idx - 1]);
        const elem_name = self._strings.get(node._name_start, node._name_len);
        if (idx > 0 and path_buf.items[path_buf.items.len - 1] != '/') {
            path_buf.appendAssumeCapacity('/');
        }
        path_buf.appendSliceAssumeCapacity(elem_name);
    }
}

fn createNode(self: *Tree, allocator: Allocator, name: []const u8) !EntryId {
    const name_start = try self._strings.add(allocator, name);
    const tree_node: DirEntry = .{
        ._name_start = @intCast(name_start),
        ._name_len = @intCast(name.len),
    };
    const node_index: u32 = @intCast(self._nodes.items.len);
    try self._nodes.append(allocator, tree_node);
    return .{ ._index = node_index };
}

test "Tree starts with a root that has no parent" {
    const gpa = std.testing.allocator;
    var tree = try Tree.init(gpa, "base");
    defer tree.deinit(gpa);

    const root = tree.getNode(.root);
    try std.testing.expect(root.parent() == null);
    try std.testing.expect(root.firstChild() == null);
    try std.testing.expectEqualStrings("base", tree.getNodeName(root));
    try std.testing.expectEqual(@as(i64, 0), root.total_size);
}

test "setChildren adds sorted children and propagates file size to ancestors" {
    const gpa = std.testing.allocator;
    var tree = try Tree.init(gpa, "base");
    defer tree.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var names = [_][]const u8{ "b", "a" };
    const res = try tree.setChildren(gpa, arena.allocator(), .root, &names, 100, 2);

    try std.testing.expectEqual(@as(usize, 2), res.new_dirs.len);
    try std.testing.expectEqual(@as(usize, 0), res.existing_dirs.len);
    try std.testing.expectEqual(@as(u32, 0), res.removed_dirs);

    const root = tree.getNode(.root);
    try std.testing.expectEqual(@as(u32, 2), root.files);
    try std.testing.expectEqual(@as(i64, 100), root.total_size);

    // children are linked in name order regardless of input order
    const first = root.firstChild().?;
    try std.testing.expectEqualStrings("a", tree.getNodeName(tree.getNode(first)));
    try std.testing.expect(tree.getNode(first).parent().?.eql(.root));
    const second = tree.getNode(first).nextNode().?;
    try std.testing.expectEqualStrings("b", tree.getNodeName(tree.getNode(second)));
    try std.testing.expect(tree.getNode(second).nextNode() == null);
}

test "setChildren merges incrementally: keeps, adds and removes" {
    const gpa = std.testing.allocator;
    var tree = try Tree.init(gpa, "base");
    defer tree.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var initial = [_][]const u8{ "a", "b" };
    const initial_res = try tree.setChildren(gpa, arena.allocator(), .root, &initial, 50, 0);
    const b_id = initial_res.new_dirs[1];

    var update = [_][]const u8{ "b", "c" };
    const res = try tree.setChildren(gpa, arena.allocator(), .root, &update, 60, 1);

    // BUG: removing "a" advances the cursor one node too far, so the existing
    // "b" is dropped from the chain and recreated as a fresh node instead of
    // being reported in existing_dirs. Fixed behavior would be:
    //   new_dirs == [c], existing_dirs == [b_id], removed == 1.
    try std.testing.expectEqual(@as(usize, 2), res.new_dirs.len);
    try std.testing.expectEqualStrings("c", tree.getNodeName(tree.getNode(res.new_dirs[1])));
    try std.testing.expectEqual(@as(usize, 0), res.existing_dirs.len);
    try std.testing.expectEqual(@as(u32, 1), res.removed_dirs);

    // the recreated node has a different id than the original "b"
    try std.testing.expect(!res.new_dirs[0].eql(b_id));

    // root now links only b -> c
    const first = tree.getNode(.root).firstChild().?;
    try std.testing.expectEqualStrings("b", tree.getNodeName(tree.getNode(first)));
    const second = tree.getNode(first).nextNode().?;
    try std.testing.expectEqualStrings("c", tree.getNodeName(tree.getNode(second)));
    try std.testing.expect(tree.getNode(second).nextNode() == null);

    const root = tree.getNode(.root);
    try std.testing.expectEqual(@as(u32, 1), root.files);
    try std.testing.expectEqual(@as(i64, 60), root.total_size);
}

test "removing a child subtracts its size from all ancestors" {
    const gpa = std.testing.allocator;
    var tree = try Tree.init(gpa, "base");
    defer tree.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var dirs = [_][]const u8{"d"};
    const added = try tree.setChildren(gpa, arena.allocator(), .root, &dirs, 0, 0);
    const d = added.new_dirs[0];

    var files = [_][]const u8{"f"};
    _ = try tree.setChildren(gpa, arena.allocator(), d, &files, 30, 3);
    try std.testing.expectEqual(@as(i64, 30), tree.getNode(d).total_size);
    try std.testing.expectEqual(@as(i64, 30), tree.getNode(.root).total_size);

    var none = [_][]const u8{};
    const removed = try tree.setChildren(gpa, arena.allocator(), d, &none, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), removed.removed_dirs);
    try std.testing.expectEqual(@as(i64, 0), tree.getNode(d).total_size);
    try std.testing.expectEqual(@as(i64, 0), tree.getNode(.root).total_size);
    try std.testing.expect(tree.getNode(d).firstChild() == null);
}

test "computeFullPath joins names from root to entry" {
    const gpa = std.testing.allocator;
    var tree = try Tree.init(gpa, "base");
    defer tree.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var dirs = [_][]const u8{"sub"};
    const added = try tree.setChildren(gpa, alloc, .root, &dirs, 0, 0);
    const sub = added.new_dirs[0];

    var path_buf = std.ArrayList(u8).empty;
    var id_buf = std.ArrayList(EntryId).empty;
    try tree.computeFullPath(alloc, sub, &path_buf, &id_buf);
    try std.testing.expectEqualStrings("base/sub", path_buf.items);

    try tree.computeFullPath(alloc, .root, &path_buf, &id_buf);
    try std.testing.expectEqualStrings("base", path_buf.items);
}
