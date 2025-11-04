const std = @import("std");
const StringPool = @import("StringPool.zig");

const Allocator = std.mem.Allocator;
const Tree = @This();

_nodes: std.ArrayList(DirEntry),
_strings: StringPool,

pub const EntryId = packed struct {
    _id: u32,

    pub const none: EntryId = .{ ._id = 0 };
    pub const root: EntryId = .{ ._id = 1 };

    pub fn isNone(self: EntryId) bool {
        return self.eql(.none);
    }

    pub fn isSome(self: EntryId) bool {
        return !self.eql(.none);
    }

    pub fn eql(self: EntryId, other: EntryId) bool {
        return self._id == other._id;
    }

    fn asIndex(self: EntryId) ?usize {
        return if (self._id == 0) null else self._id - 1;
    }

    fn fromIndex(index: usize) EntryId {
        return .{ ._id = @intCast(index + 1) };
    }
};

pub const DirEntry = struct {
    _name_start: u32,
    _name_len: u16,

    first_child: EntryId = .none,
    next_node: EntryId = .none,
    parent: EntryId = .none,

    /// Size of all its children
    total_size: i64,
};

pub fn init(allocator: Allocator, root: []const u8) !Tree {
    var tree = Tree{
        ._nodes = std.ArrayList(DirEntry).empty,
        ._strings = .{},
    };
    const id = try tree.addNode(allocator, .{
        .name = root,
    });
    std.debug.assert(id._id == EntryId.root._id);
    return tree;
}

pub fn deinit(self: *Tree, allocator: Allocator) void {
    self._nodes.deinit(allocator);
    self._strings.deinit(allocator);
}

pub fn addSize(self: *Tree, dir_id: EntryId, size: i64) void {
    var current = dir_id;
    while (current.asIndex()) |index| {
        self._nodes.items[index].total_size += size;
        current = self._nodes.items[index].parent;
    }
}

pub const NewNode = struct {
    name: []const u8,
    parent: EntryId = .none,
};

pub fn addNode(self: *Tree, allocator: Allocator, node: NewNode) !EntryId {
    const name_start = try self._strings.add(allocator, node.name);

    var tree_node = DirEntry{
        ._name_start = @intCast(name_start),
        ._name_len = @intCast(node.name.len),
        .parent = node.parent,
        .total_size = 0,
    };
    const node_id: EntryId = .fromIndex(self._nodes.items.len);

    if (node.parent.asIndex()) |index| {
        var parent: *DirEntry = &self._nodes.items[index];
        const prev_first = parent.first_child;
        parent.first_child = node_id;
        tree_node.next_node = prev_first;
    }
    try self._nodes.append(allocator, tree_node);

    return node_id;
}

pub fn getNode(self: Tree, id: EntryId) ?DirEntry {
    if (id.asIndex()) |index| {
        if (index < self._nodes.items.len) {
            return self._nodes.items[index];
        }
    }
    return null;
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
    while (self.getNode(current)) |node| {
        try id_buf.append(allocator, current);
        if (total_path_size > 0) {
            //separator
            total_path_size += 1;
        }
        total_path_size += node._name_len;
        current = node.parent;
    }
    path_buf.clearRetainingCapacity();
    try path_buf.ensureTotalCapacity(allocator, total_path_size);
    for (0..id_buf.items.len) |idx| {
        const node = self.getNode(id_buf.items[id_buf.items.len - idx - 1]) orelse break;
        const elem_name = self._strings.get(node._name_start, node._name_len);
        if (idx > 0) {
            path_buf.appendAssumeCapacity('/');
        }
        path_buf.appendSliceAssumeCapacity(elem_name);
    }
}
