const std = @import("std");

//TODO correct for different platforms
pub const fsblkcnt_t = u64;
pub const fsfilcnt_t = u64;

pub const struct_statvfs = extern struct {
    /// file system block size
    f_bsize: c_ulong,

    /// fragment size
    f_frsize: c_ulong,

    /// size of fs in f_frsize units
    f_blocks: fsblkcnt_t,

    /// free blocks
    f_bfree: fsblkcnt_t,

    /// free blocks for non-root
    f_bavail: fsblkcnt_t,

    /// inodes
    f_files: fsfilcnt_t,

    /// free inodes
    f_ffree: fsfilcnt_t,

    /// free inodes for non-root
    f_favail: fsfilcnt_t,

    /// file system ID
    f_fsid: c_ulong,

    /// mount flags
    f_flag: c_ulong,

    /// maximum filename length
    f_namemax: c_ulong,

    __unused: [6]c_int,
};

pub extern fn statvfs(noalias __file: [*c]const u8, noalias __buf: [*c]struct_statvfs) c_int;
pub extern fn fstatvfs(__fildes: c_int, __buf: [*c]struct_statvfs) c_int;

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
