const std = @import("std");
const StringPool = @import("StringPool.zig");

const Allocator = std.mem.Allocator;
const Tree = @This();

pub const root_id: u32 = 1;

_nodes: std.ArrayList(DirEntry),
_strings: StringPool,

pub const DirEntry = struct {
    _name_start: u32,
    _name_len: u16,

    first_child: u32 = 0,
    next_node: u32 = 0,
    parent: u32 = 0,

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
    std.debug.assert(root_id == id);
    return tree;
}

pub fn deinit(self: *Tree, allocator: Allocator) void {
    self._nodes.deinit(allocator);
    self._strings.deinit(allocator);
}

pub fn addSize(self: *Tree, dir_index: u32, size: i64) void {
    var current = dir_index;
    while (current != 0) {
        self._nodes.items[current - 1].total_size += size;
        current = self._nodes.items[current - 1].parent;
    }
}

pub const NewNode = struct {
    name: []const u8,
    parent: u32 = 0,
};

pub fn addNode(self: *Tree, allocator: Allocator, node: NewNode) !u32 {
    const name_start = try self._strings.add(allocator, node.name);

    var tree_node = DirEntry{
        ._name_start = @intCast(name_start),
        ._name_len = @intCast(node.name.len),
        .parent = node.parent,
        .total_size = 0,
    };
    const node_index: u32 = @intCast(self._nodes.items.len + 1);

    if (node.parent > 0) {
        var parent: *DirEntry = &self._nodes.items[node.parent - 1];
        const prev_first = parent.first_child;
        parent.first_child = node_index;
        tree_node.next_node = prev_first;
    }
    try self._nodes.append(allocator, tree_node);

    return node_index;
}

pub fn getNode(self: Tree, index: u32) ?DirEntry {
    if (index == 0 or index > self._nodes.items.len) {
        return null;
    }
    return self._nodes.items[index - 1];
}

pub fn getNodeName(self: Tree, entry: DirEntry) []const u8 {
    return self._strings.get(entry._name_start, entry._name_len);
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
    while (self.getNode(current)) |node| {
        try index_buf.append(allocator, current);
        if (total_path_size > 0) {
            //separator
            total_path_size += 1;
        }
        total_path_size += node._name_len;
        current = node.parent;
    }
    path_buf.clearRetainingCapacity();
    try path_buf.ensureTotalCapacity(allocator, total_path_size);
    for (0..index_buf.items.len) |idx| {
        const node = self.getNode(index_buf.items[index_buf.items.len - idx - 1]) orelse break;
        const elem_name = self._strings.get(node._name_start, node._name_len);
        if (idx > 0) {
            path_buf.appendAssumeCapacity('/');
        }
        path_buf.appendSliceAssumeCapacity(elem_name);
    }
}
