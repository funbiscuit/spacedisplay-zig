//! Fixed-capacity LIFO ring. Not synchronized: callers guard concurrent
//! access externally.

const std = @import("std");

pub fn Queue(comptime T: type, N: comptime_int) type {
    return struct {
        _elements: [N]T = undefined,
        _len: usize = 0,

        const Self = @This();

        pub fn putBack(self: *Self, item: T) !void {
            if (self._len == self._elements.len) {
                return error.NoSpace;
            }
            self._elements[self._len] = item;
            self._len += 1;
        }

        pub fn popBack(self: *Self) ?T {
            if (self._len == 0) {
                return null;
            }
            self._len -= 1;
            return self._elements[self._len];
        }
    };
}

test "Queue is LIFO and bounded" {
    var q = Queue(u32, 2){};

    try std.testing.expect(q.popBack() == null);

    try q.putBack(1);
    try q.putBack(2);
    try std.testing.expectError(error.NoSpace, q.putBack(3));

    try std.testing.expectEqual(@as(?u32, 2), q.popBack());
    try std.testing.expectEqual(@as(?u32, 1), q.popBack());
    try std.testing.expect(q.popBack() == null);
}
