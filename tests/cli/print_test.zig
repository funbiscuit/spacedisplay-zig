//! CLI e2e tests: the --no-ui --print tree dump.

const std = @import("std");
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");

const gpa = std.testing.allocator;

test "binary dumps scanned tree with --print" {
    var fixture = try fixtures.PrintFixture.create();
    defer fixture.destroy();

    var run = try harness.runBinary(&.{"--print"}, fixture.path);
    defer run.deinit();

    const expected = try std.fmt.allocPrint(gpa,
        \\350 B  {s}/
        \\300 B  └── a/
        \\200 B      └── b/
        \\
    , .{fixture.path});
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, run.output);
}

test "binary respects --max-depth and --min-size" {
    var fixture = try fixtures.PrintFixture.create();
    defer fixture.destroy();

    // depth 1: root and a, but not a/b
    var run = try harness.runBinary(&.{ "--print", "--max-depth", "1" }, fixture.path);
    defer run.deinit();
    const expected = try std.fmt.allocPrint(gpa,
        \\350 B  {s}/
        \\300 B  └── a/
        \\
    , .{fixture.path});
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, run.output);

    // min size 250: a/b (200) is pruned, a (300) and root (350) remain
    var run2 = try harness.runBinary(&.{ "--print", "--min-size", "250" }, fixture.path);
    defer run2.deinit();
    try std.testing.expectEqualStrings(expected, run2.output);
}
