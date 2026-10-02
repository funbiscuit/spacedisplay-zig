const std = @import("std");
const c = std.c;
const linux = std.os.linux;
const posix = @import("platform/posix.zig");
const ScanEngine = @import("core/ScanEngine.zig");

const Allocator = std.mem.Allocator;

pub const MountStats = ScanEngine.MountStats;

pub fn canScan(allocator: Allocator, parent_path: []const u8, child: []const u8) !bool {
    const parent_pathz = try allocator.dupeZ(u8, parent_path);
    defer allocator.free(parent_pathz);

    const child_path = std.fs.path.resolve(
        allocator,
        &[_][]const u8{ parent_path, child },
    ) catch return false;
    defer allocator.free(child_path);

    const child_pathz = try allocator.dupeZ(u8, child_path);
    defer allocator.free(child_pathz);

    if (devOf(child_pathz)) |child_dev| {
        if (devOf(parent_pathz)) |parent_dev| {
            return child_dev == parent_dev;
        }
    }
    return false;
}

pub fn getMountStats(allocator: Allocator, path: []const u8) Allocator.Error!?MountStats {
    const abs_path = realpathAlloc(allocator, path) orelse return null;
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
        if (devOf(abs_pathz)) |dev1| {
            const parent_pathz = try allocator.dupeZ(u8, parent_abs_path);
            defer allocator.free(parent_pathz);
            if (devOf(parent_pathz)) |dev2| {
                break :blk dev1 != dev2;
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

/// Resolves `path` against symlinks; null when it does not exist. The result
/// is owned by `allocator`.
fn realpathAlloc(allocator: Allocator, path: []const u8) ?[]u8 {
    const pathz = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(pathz);

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = c.realpath(pathz, &buf) orelse return null;
    return allocator.dupe(u8, std.mem.span(resolved)) catch null;
}

/// Device id of the filesystem holding `path`; null when it does not exist.
/// std.Io.File.Stat carries no device id, so this goes through statx(2).
fn devOf(path: [:0]const u8) ?u64 {
    var stx: linux.Statx = std.mem.zeroes(linux.Statx);
    const rc = c.statx(std.posix.AT.FDCWD, path, 0, .{
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
