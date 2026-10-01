//! Core namespace: pure data structures live in the core/ directory.

const std = @import("std");

pub const Tree = @import("core/Tree.zig");
pub const StringPool = @import("core/StringPool.zig");
pub const queue = @import("core/queue.zig");

test {
    std.testing.refAllDecls(@This());
}
