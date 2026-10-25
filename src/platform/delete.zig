//! Portable deletion of a file, symlink, or empty directory.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn deletePath(dir: std.Io.Dir, io: std.Io, sub_path: []const u8) !void {
    // A plain file or symlink — the common case.
    if (dir.deleteFile(io, sub_path)) {
        return;
    } else |err| switch (err) {
        error.IsDir => {},
        else => return err,
    }

    // An empty directory.
    if (dir.deleteDir(io, sub_path)) {
        return;
    } else |err| {
        return err;
    }
}

test "deletePath removes a file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try tmp.dir.createFile(io, "file.bin", .{});
    defer f.close(io);
    try f.writeStreamingAll(io, "content");

    try deletePath(tmp.dir, io, "file.bin");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "file.bin", .{}));
}

test "deletePath removes an empty directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "empty", .default_dir);

    try deletePath(tmp.dir, io, "empty");
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "empty", .{}));
}

test "deletePath does not remove a directory tree" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "a/b/c");
    {
        var f = try tmp.dir.createFile(io, "a/deep.bin", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "deep");
    }
    {
        var f = try tmp.dir.createFile(io, "a/b/c/leaf.bin", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "leaf");
    }

    try std.testing.expectError(error.DirNotEmpty, deletePath(tmp.dir, io, "a"));
}

test "deletePath reports a missing path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.FileNotFound, deletePath(tmp.dir, io, "missing"));
}
