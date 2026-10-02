//! Harness for CLI e2e tests: runs the built binary.

const std = @import("std");
const test_options = @import("test_options");

const gpa = std.testing.allocator;
const io = std.testing.io;

pub const Run = struct {
    output: []u8,

    pub fn deinit(self: *Run) void {
        gpa.free(self.output);
    }
};

/// Spawns the built binary with --no-ui, the given args and the fixture
/// path; returns stdout and asserts a clean exit.
pub fn runBinary(args: []const []const u8, fixture_path: []const u8) !Run {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ test_options.exe_path, "--no-ui" });
    try argv.appendSlice(gpa, args);
    try argv.append(gpa, fixture_path);

    const result = try std.process.run(gpa, io, .{ .argv = argv.items });
    errdefer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    gpa.free(result.stderr);
    return .{ .output = result.stdout };
}
