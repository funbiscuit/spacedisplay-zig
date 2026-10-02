//! Harness for CLI e2e tests: runs the built binary.

const std = @import("std");
const test_options = @import("test_options");

const gpa = std.testing.allocator;

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

    var child = std.process.Child.init(argv.items, gpa);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const output = try child.stdout.?.readToEndAlloc(gpa, 1 << 20);
    errdefer gpa.free(output);
    const term = try child.wait();
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return .{ .output = output };
}
