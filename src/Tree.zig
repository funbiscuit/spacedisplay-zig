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

pub fn addSize(self: *Tree, dir_id: EntryId, size: i64) void {
    var current_id: ?EntryId = dir_id;
    while (current_id) |id| {
        self._nodes.items[id._index].total_size += size;
        current_id = self._nodes.items[id._index].parent();
    }
}

pub fn addNode(self: *Tree, allocator: Allocator, node: anytype) !EntryId {
    if (@typeInfo(@TypeOf(node)) != .@"struct") {
        @compileError("Expected struct type, got " ++ @typeName(@TypeOf(node)));
    }

    const name_start = try self._strings.add(allocator, node.name);
    var tree_node: DirEntry = .{
        ._name_start = @intCast(name_start),
        ._name_len = @intCast(node.name.len),
        ._parent = node.parent._index + 1,
        .total_size = 0,
    };
    const node_index: u32 = @intCast(self._nodes.items.len);

    var parent: *DirEntry = &self._nodes.items[node.parent._index];
    const prev_first = parent._first_child;
    parent._first_child = node_index + 1;
    tree_node._next_node = prev_first;

    try self._nodes.append(allocator, tree_node);

    return .{ ._index = node_index };
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
        if (idx > 0) {
            path_buf.appendAssumeCapacity('/');
        }
        path_buf.appendSliceAssumeCapacity(elem_name);
    }
}
