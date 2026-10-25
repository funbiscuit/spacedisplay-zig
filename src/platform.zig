//! Mount stats, mount-boundary checks, and deletion; per-OS backends in
//! platform/, portable shared logic here.

const std = @import("std");
const builtin = @import("builtin");
const delete = @import("platform/delete.zig");
const ScanEngine = @import("core/ScanEngine.zig");

const backend = switch (builtin.os.tag) {
    .linux => @import("platform/linux.zig"),
    .macos => @import("platform/macos.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("unsupported operating system"),
};

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const MountStats = ScanEngine.MountStats;

/// Deletes whatever `sub_path` turns out to be on disk: a file, a symlink
/// (removed, never followed), or an empty directory. Non empty directories
/// are not removed and `DirNotEmpty` error is returned.
pub fn deletePath(dir: Io.Dir, io: Io, sub_path: []const u8) !void {
    return delete.deletePath(dir, io, sub_path);
}

test {
    std.testing.refAllDecls(@This());
}

pub fn canScan(io: Io, allocator: Allocator, parent_path: []const u8, child: []const u8) !bool {
    const child_path = std.fs.path.resolve(
        allocator,
        &[_][]const u8{ parent_path, child },
    ) catch return false;
    defer allocator.free(child_path);

    if (backend.devOf(io, allocator, child_path)) |child_dev| {
        if (backend.devOf(io, allocator, parent_path)) |parent_dev| {
            return child_dev == parent_dev;
        }
    }
    return false;
}

pub fn getMountStats(io: Io, allocator: Allocator, path: []const u8) Allocator.Error!?MountStats {
    const abs_path = realpathAlloc(io, allocator, path) orelse return null;
    defer allocator.free(abs_path);
    const space = backend.spaceOf(io, allocator, abs_path) orelse return null;

    const maybe_parent_abs_path = std.fs.path.dirname(abs_path);
    const is_mount_point = if (maybe_parent_abs_path) |parent_abs_path| blk: {
        if (backend.devOf(io, allocator, abs_path)) |dev1| {
            if (backend.devOf(io, allocator, parent_abs_path)) |dev2| {
                break :blk dev1 != dev2;
            }
        }
        break :blk false;
    } else true;

    return .{
        .total = space.total,
        .available = space.available,
        .reserved = space.reserved,
        .is_mount_point = is_mount_point,
    };
}

/// Resolves `path` against symlinks; null when it does not exist. The result
/// is owned by `allocator`.
fn realpathAlloc(io: Io, allocator: Allocator, path: []const u8) ?[]u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return null;
    var resolved = buf[0..n];
    // Windows canonical paths carry a \\?\ prefix that no user wants to
    // see; everything accepts the plain drive-letter form.
    if (std.mem.startsWith(u8, resolved, "\\\\?\\")) resolved = resolved[4..];
    return allocator.dupe(u8, resolved) catch return null;
}
