const std = @import("std");
const cli = @import("cli.zig");
const fmt = std.fmt;
const log = std.log;
const vaxis = @import("vaxis");

const Allocator = std.mem.Allocator;

var start_time: i64 = 0;
pub var allow_log = std.atomic.Value(bool).init(true);

pub fn myLogFn(
    comptime message_level: log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (allow_log.load(.seq_cst)) {
        const level_txt = comptime message_level.asText();
        const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderrWriter(&buffer);
        defer std.debug.unlockStderrWriter();

        const ms = std.time.milliTimestamp() - start_time;

        stderr.print("{d} " ++ level_txt ++ prefix2, .{ms}) catch return;
        stderr.print(format ++ "\n", args) catch return;
        stderr.flush() catch return;
    }
}

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = myLogFn,
};

pub const panic = vaxis.panic_handler;

pub fn main() !u8 {
    start_time = std.time.milliTimestamp();
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    return cli.run(allocator);
}

test {
    std.testing.refAllDecls(@This());
}
