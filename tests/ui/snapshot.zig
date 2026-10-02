//! Golden snapshot comparison. Regenerate with UPDATE_SNAPSHOTS=1 in the
//! environment, then review the diff before committing.

const std = @import("std");
const test_options = @import("test_options");
const harness = @import("harness.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;

/// Asserts both golden formats for a rendered widget: `<name>.txt` (layout)
/// and `<name>.ansi` (styles as SGR escapes).
pub fn expectGolden(name: []const u8, rendered: harness.Rendered) !void {
    try expectFile(name, "txt", rendered.text);
    try expectFile(name, "ansi", rendered.ansi);
}

fn expectFile(name: []const u8, ext: []const u8, actual: []const u8) !void {
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}.{s}", .{ test_options.snapshot_dir, name, ext });
    defer gpa.free(path);

    if (std.process.Environ.getPosix(std.testing.environ, "UPDATE_SNAPSHOTS") != null) {
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, actual);
        return;
    }

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("snapshot {s} is missing; run with UPDATE_SNAPSHOTS=1 to create it\n", .{name});
            return error.MissingSnapshot;
        },
        else => return err,
    };
    defer file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &reader_buf);
    const expected = try file_reader.interface.allocRemaining(gpa, .limited(1 << 20));
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, actual);
}
