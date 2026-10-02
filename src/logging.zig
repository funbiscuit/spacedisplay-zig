//! Stderr logging with relative timestamps. `allow_log` lets the TUI silence
//! logs while the alternate screen is active.

const std = @import("std");

var start_time: std.Io.Timestamp = .zero;

//TODO show logs in separate TUI screen
/// Global kill switch for logging; the TUI turns it off while running.
pub var allow_log = std.atomic.Value(bool).init(true);

pub fn init(io: std.Io) void {
    start_time = std.Io.Clock.awake.now(io);
}

pub fn myLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (allow_log.load(.seq_cst)) {
        const level_txt = comptime message_level.asText();
        const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

        const io = std.Options.debug_io;
        const ms = start_time.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

        var buffer: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buffer);
        defer std.debug.unlockStderr();

        stderr.file_writer.interface.print("{d} " ++ level_txt ++ prefix2, .{ms}) catch return;
        stderr.file_writer.interface.print(format ++ "\n", args) catch return;
        stderr.file_writer.interface.flush() catch return;
    }
}
