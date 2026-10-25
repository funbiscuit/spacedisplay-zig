//! Linux backend: statx(2) for device ids, statvfs(3) for disk space.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Space = struct { total: u64, available: u64, reserved: u64 };

const fsblkcnt_t = u64;
const fsfilcnt_t = u64;

/// glibc's struct statvfs layout; other libc variants differ.
const struct_statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: fsblkcnt_t,
    f_bfree: fsblkcnt_t,
    f_bavail: fsblkcnt_t,
    f_files: fsfilcnt_t,
    f_ffree: fsfilcnt_t,
    f_favail: fsfilcnt_t,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    __unused: [6]c_int,
};

extern fn statvfs(noalias file: [*:0]const u8, noalias buf: *struct_statvfs) c_int;

/// Device id of the filesystem holding `path`; null when it does not exist.
/// std.Io.File.Stat carries no device id, so this goes through statx(2).
pub fn devOf(io: Io, allocator: Allocator, path: []const u8) ?u64 {
    _ = io;
    const linux = std.os.linux;
    const pathz = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(pathz);
    var stx: linux.Statx = std.mem.zeroes(linux.Statx);
    const rc = std.c.statx(std.posix.AT.FDCWD, pathz, 0, .{
        .TYPE = true,
        .MODE = true,
        .NLINK = true,
        .UID = true,
        .GID = true,
        .ATIME = true,
        .MTIME = true,
        .CTIME = true,
        .INO = true,
        .SIZE = true,
        .BLOCKS = true,
    }, &stx);
    if (rc != 0) {
        return null;
    }
    return (@as(u64, stx.dev_major) << 32) | stx.dev_minor;
}

pub fn spaceOf(io: Io, allocator: Allocator, path: []const u8) ?Space {
    _ = io;
    const pathz = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(pathz);

    var res: struct_statvfs = std.mem.zeroes(struct_statvfs);
    if (statvfs(pathz, &res) != 0) {
        return null;
    }

    const block_size: u64 = if (res.f_frsize > 0) @intCast(res.f_frsize) else @intCast(res.f_bsize);
    const total_blocks: u64 = @intCast(res.f_blocks);
    const available_blocks_for_root: u64 = @intCast(res.f_bfree);
    const available_blocks: u64 = @intCast(res.f_bavail);

    return .{
        .total = total_blocks * block_size,
        .available = available_blocks * block_size,
        .reserved = (available_blocks_for_root - available_blocks) * block_size,
    };
}
