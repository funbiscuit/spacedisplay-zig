const std = @import("std");

const Allocator = std.mem.Allocator;
const StringPool = @This();

_buffer: std.ArrayList(u8) = std.ArrayList(u8).empty,

pub fn deinit(self: *StringPool, allocator: Allocator) void {
    self._buffer.deinit(allocator);
}

/// Adds given slice to pool and returns its position in it for future access
pub fn add(self: *StringPool, allocator: Allocator, slice: []const u8) !usize {
    const index = self._buffer.items.len;
    try self._buffer.appendSlice(allocator, slice);
    return index;
}

pub fn get(self: StringPool, index: usize, len: usize) []const u8 {
    return self._buffer.items[index .. index + len];
}

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
