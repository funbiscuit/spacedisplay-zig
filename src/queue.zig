const std = @import("std");

const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

pub fn Queue(comptime T: type, N: comptime_int) type {
    return struct {
        _mutex: Mutex = .{},
        _cond: Condition = .{},
        _elements: [N]T = undefined,
        _len: usize = 0,

        const Self = @This();

        pub fn putBack(self: *Self, item: T) !void {
            self._mutex.lock();
            defer self._mutex.unlock();
            if (self._len == self._elements.len) {
                return error.NoSpace;
            }
            self._elements[self._len] = item;
            self._len += 1;
        }

        pub fn popBack(self: *Self) ?T {
            self._mutex.lock();
            defer self._mutex.unlock();
            if (self._len == 0) {
                return null;
            }
            self._len -= 1;
            return self._elements[self._len];
        }
    };
}
