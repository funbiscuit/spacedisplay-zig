const std = @import("std");
const c = std.c;
const posix = @import("platform/posix.zig");

const Allocator = std.mem.Allocator;

pub const MountStats = struct {
    /// Total size of partition
    total: u64,

    /// Available space on partition
    available: u64,

    /// Reserved space for root
    reserved: u64,

    /// Whether info was requested for mount point (true)
    /// or for some directory inside mount point
    is_mount_point: bool,
};

pub fn getMountStats(allocator: Allocator, path: []const u8) Allocator.Error!?MountStats {
    const abs_path = std.fs.cwd().realpathAlloc(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(abs_path);
    const abs_pathz = try allocator.dupeZ(u8, abs_path);
    defer allocator.free(abs_pathz);

    var res: posix.struct_statvfs = std.mem.zeroes(posix.struct_statvfs);
    const errno = posix.statvfs(abs_pathz, &res);
    if (errno != 0) {
        return null;
    }

    const maybe_parent_abs_path = std.fs.path.dirname(abs_path);
    const is_mount_point = if (maybe_parent_abs_path) |parent_abs_path| blk: {
        if (statPath(abs_pathz)) |stat1| {
            const parent_pathz = try allocator.dupeZ(u8, parent_abs_path);
            defer allocator.free(parent_pathz);
            if (statPath(parent_pathz)) |stat2| {
                break :blk stat1.dev != stat2.dev;
            }
        }
        break :blk false;
    } else true;

    const block_size: u64 = if (res.f_frsize > 0) @intCast(res.f_frsize) else @intCast(res.f_bsize);
    const total_blocks: u64 = @intCast(res.f_blocks);
    const available_blocks_for_root: u64 = @intCast(res.f_bfree);
    const available_blocks: u64 = @intCast(res.f_bavail);

    return .{
        .total = total_blocks * block_size,
        .available = available_blocks * block_size,
        .reserved = (available_blocks_for_root - available_blocks) * block_size,
        .is_mount_point = is_mount_point,
    };
}

fn statPath(path: [:0]const u8) ?c.Stat {
    var stat: c.Stat = std.mem.zeroes(c.Stat);

    const err = std.c.stat(path, &stat);
    if (err != 0) {
        std.log.warn("Failed to stat {s}: {d}", .{ path, err });
        return null;
    }
    return stat;
}
