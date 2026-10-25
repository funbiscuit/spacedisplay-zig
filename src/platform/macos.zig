//! macOS backend: stat(2) for device ids, statvfs(3) for disk space.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Space = struct { total: u64, available: u64, reserved: u64 };

extern fn stat(path: [*:0]const u8, buf: *std.posix.Stat) c_int;

/// Darwin's struct statvfs (sys/statvfs.h, verified against the SDK
/// headers zig bundles): unsigned long block sizes, uint64 counters, and
/// none of the name arrays statfs carries.
const struct_statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
};

extern fn statvfs(path: [*:0]const u8, buf: *struct_statvfs) c_int;

/// Device id of the filesystem holding `path`; null when it does not
/// exist. Only equality is ever compared, so the raw st_dev value is
/// enough — no major/minor split like statx gives on Linux.
pub fn devOf(io: Io, allocator: Allocator, path: []const u8) ?u64 {
    _ = io;
    const pathz = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(pathz);
    var st: std.posix.Stat = undefined;
    if (stat(pathz, &st) != 0) {
        return null;
    }
    return @intCast(st.dev);
}

pub fn spaceOf(io: Io, allocator: Allocator, path: []const u8) ?Space {
    _ = io;
    const pathz = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(pathz);

    var res: struct_statvfs = std.mem.zeroes(struct_statvfs);
    if (statvfs(pathz, &res) != 0) {
        return null;
    }

    const block_size: u64 = if (res.f_frsize > 0) res.f_frsize else res.f_bsize;
    const total_blocks: u64 = res.f_blocks;
    const available_blocks_for_root: u64 = res.f_bfree;
    const available_blocks: u64 = res.f_bavail;

    return .{
        .total = total_blocks * block_size,
        .available = available_blocks * block_size,
        .reserved = (available_blocks_for_root - available_blocks) * block_size,
    };
}
