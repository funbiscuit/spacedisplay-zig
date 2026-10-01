//! Stderr logging with relative timestamps. `allow_log` lets the TUI silence
//! logs while the alternate screen is active.

const std = @import("std");

var start_time: i64 = 0;

//TODO show logs in separate TUI screen
/// Global kill switch for logging; the TUI turns it off while running.
pub var allow_log = std.atomic.Value(bool).init(true);

pub fn init() void {
    start_time = std.time.milliTimestamp();
}

pub fn myLogFn(
    comptime message_level: std.log.Level,
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
