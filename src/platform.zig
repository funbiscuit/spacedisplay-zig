//! Directory listing, mount stats, and deletion; per-OS backends in
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
pub const DirListing = ScanEngine.DirListing;

/// Deletes whatever `sub_path` turns out to be on disk: a file, a symlink
/// (removed, never followed), or an empty directory. Non empty directories
/// are not removed and `DirNotEmpty` error is returned.
pub fn deletePath(dir: Io.Dir, io: Io, sub_path: []const u8) !void {
    return delete.deletePath(dir, io, sub_path);
}

test {
    std.testing.refAllDecls(@This());
}

/// Lists one directory: entry names are owned by `arena`. `missing` is
/// set when the directory could not be opened at all; an error during
/// iteration yields a partial listing. Backends with a cheaper
/// primitive replace `defaultListDir`.
pub const listDir = if (@hasDecl(backend, "listDir")) backend.listDir else defaultListDir;

fn defaultListDir(io: Io, arena: Allocator, dir_path: []const u8) Allocator.Error!DirListing {
    var entries = std.ArrayList(ScanEngine.DirEntry).empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Failed to open `{s}`: {any}", .{ dir_path, err });
        return .{ .entries = entries.items, .missing = true };
    };
    defer dir.close(io);

    var it = dir.iterateAssumeFirstIteration();
    while (true) {
        const entry = it.next(io) catch |err| {
            std.log.warn("Failed to iterate in `{s}`: {any}", .{ dir_path, err });
            break;
        } orelse break;
        const name = try arena.dupe(u8, entry.name);
        switch (entry.kind) {
            .directory => {
                const can_scan = try canScan(io, arena, dir_path, name);
                try entries.append(arena, .{
                    .name = name,
                    .size = 0,
                    .kind = .directory,
                    .can_scan = can_scan,
                });
            },
            .file => {
                const stats = dir.statFile(io, entry.name, .{}) catch |err| {
                    std.log.warn("Failed to stat file `{s}/{s}`: {any}", .{ dir_path, entry.name, err });
                    continue;
                };
                try entries.append(arena, .{
                    .name = name,
                    .size = stats.size,
                    .kind = .file,
                });
            },
            // no stat: it would follow the link, and the link itself is
            // what deletions act on
            .sym_link => {
                try entries.append(arena, .{
                    .name = name,
                    .size = 0,
                    .kind = .sym_link,
                });
            },
            else => {},
        }
    }

    return .{ .entries = entries.items };
}

fn canScan(io: Io, allocator: Allocator, parent_path: []const u8, child: []const u8) !bool {
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
