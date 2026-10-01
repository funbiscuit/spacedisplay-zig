//! Golden snapshot comparison. Regenerate with UPDATE_SNAPSHOTS=1 in the
//! environment, then review the diff before committing.

const std = @import("std");
const test_options = @import("test_options");
const harness = @import("harness.zig");

const gpa = std.testing.allocator;

/// Asserts both golden formats for a rendered widget: `<name>.txt` (layout)
/// and `<name>.ansi` (styles as SGR escapes).
pub fn expectGolden(name: []const u8, rendered: harness.Rendered) !void {
    try expectFile(name, "txt", rendered.text);
    try expectFile(name, "ansi", rendered.ansi);
}

fn expectFile(name: []const u8, ext: []const u8, actual: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.{s}", .{ test_options.snapshot_dir, name, ext });
    defer gpa.free(path);

    if (std.posix.getenv("UPDATE_SNAPSHOTS") != null) {
        if (std.fs.path.dirname(path)) |dir| std.fs.makeDirAbsolute(dir) catch {};
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(actual);
        return;
    }

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("snapshot {s} is missing; run with UPDATE_SNAPSHOTS=1 to create it\n", .{name});
            return error.MissingSnapshot;
        },
        else => return err,
    };
    defer file.close();
    const expected = try file.readToEndAlloc(gpa, 1 << 20);
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
}
