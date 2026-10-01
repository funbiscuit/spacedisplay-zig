//! Executable entry point.
//! All application code lives in the spacedisplay library module.

const std = @import("std");
const spacedisplay = @import("spacedisplay");

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = spacedisplay.logging.myLogFn,
};

pub const panic = spacedisplay.vaxis.panic_handler;

pub fn main() !u8 {
    spacedisplay.logging.init();
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    return spacedisplay.cli.run(allocator);
}
