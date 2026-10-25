//! Windows backend: directory listing reads sizes straight from the
//! enumeration records, volume serial numbers identify volumes (the role
//! st_dev plays on POSIX), disk space comes from GetDiskFreeSpaceExW.

const std = @import("std");
const win32 = std.os.windows;
const ScanEngine = @import("../core/ScanEngine.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Space = struct { total: u64, available: u64, reserved: u64 };

/// Names are at most 255 UTF-16 units, so one record is well under a
/// kilobyte; this batches hundreds of entries per syscall.
const dir_info_buffer_len = 64 * 1024;

/// Lists one directory with a plain NtQueryDirectoryFile walk: name,
/// attributes and size are in every record, so no entry needs its own
/// handle — locked and ACL-protected files are listed with their sizes
/// instead of failing an open (std's open-based `statFile` retries locked
/// files for ~4s and then drops them). Plain directories are always on
/// the same volume as their parent: cross-volume children (mounted
/// folders, junctions) are reparse points, caught by the kind check.
pub fn listDir(io: Io, arena: Allocator, dir_path: []const u8) Allocator.Error!ScanEngine.DirListing {
    var entries: std.ArrayList(ScanEngine.DirEntry) = .empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Failed to open `{s}`: {any}", .{ dir_path, err });
        return .{ .entries = entries.items, .missing = true };
    };
    defer dir.close(io);

    var buf: [dir_info_buffer_len]u8 align(@alignOf(win32.FILE_BOTH_DIR_INFORMATION)) = undefined;
    var restart_scan = true;
    while (true) {
        var iosb: win32.IO_STATUS_BLOCK = undefined;
        const rc = win32.ntdll.NtQueryDirectoryFile(
            dir.handle,
            null,
            null,
            null,
            &iosb,
            &buf,
            @intCast(buf.len),
            .BothDirectory,
            .FALSE,
            null,
            .fromBool(restart_scan),
        );
        restart_scan = false;
        if (iosb.Information == 0) break;

        const records: []align(@alignOf(win32.FILE_BOTH_DIR_INFORMATION)) u8 = buf[0..iosb.Information];
        var it = win32.FileInformationIterator(win32.FILE_BOTH_DIR_INFORMATION){ .buf = records };
        while (it.next()) |info| {
            const name_w = info.FileName[0 .. info.FileNameLength / 2];
            if (std.mem.eql(u16, name_w, &[_]u16{'.'}) or std.mem.eql(u16, name_w, &[_]u16{ '.', '.' })) {
                continue;
            }
            const name = try std.unicode.wtf16LeToWtf8Alloc(arena, name_w);
            const attrs = info.FileAttributes;
            if (attrs.REPARSE_POINT) {
                // never followed: the link itself is what deletions act on
                try entries.append(arena, .{ .name = name, .size = 0, .kind = .sym_link });
            } else if (attrs.DIRECTORY) {
                try entries.append(arena, .{ .name = name, .size = 0, .kind = .directory, .can_scan = true });
            } else {
                try entries.append(arena, .{ .name = name, .size = @intCast(@max(0, info.EndOfFile)), .kind = .file });
            }
        }

        switch (rc) {
            .SUCCESS => {},
            .NO_MORE_FILES => break,
            else => {
                std.log.warn("Failed to enumerate `{s}`: {any}", .{ dir_path, win32.unexpectedStatus(rc) });
                break;
            },
        }
    }

    return .{ .entries = entries.items };
}

const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    nNumberOfLinks: u32,
    nFileIndexHigh: u32,
    nFileIndexLow: u32,
};

extern "kernel32" fn GetFileInformationByHandle(
    hFile: win32.HANDLE,
    lpFileInformation: *BY_HANDLE_FILE_INFORMATION,
) callconv(.winapi) c_int;

extern "kernel32" fn GetDiskFreeSpaceExW(
    lpDirectoryName: [*:0]const u16,
    lpFreeBytesAvailableToCaller: *u64,
    lpTotalNumberOfBytes: *u64,
    lpTotalNumberOfFreeBytes: *u64,
) callconv(.winapi) c_int;

/// Volume serial of the volume holding `path`; null when it does not
/// exist. Io.Dir's handle is the Win32 HANDLE on this target.
pub fn devOf(io: Io, allocator: Allocator, path: []const u8) ?u64 {
    _ = allocator;
    var dir = Io.Dir.cwd().openDir(io, path, .{}) catch return null;
    defer dir.close(io);
    var info: BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(dir.handle, &info) == 0) {
        return null;
    }
    return info.dwVolumeSerialNumber;
}

pub fn spaceOf(io: Io, allocator: Allocator, path: []const u8) ?Space {
    _ = io;
    const pathw = std.unicode.wtf8ToWtf16LeAllocZ(allocator, path) catch return null;
    defer allocator.free(pathw);

    var available: u64 = 0;
    var total: u64 = 0;
    var total_free: u64 = 0;
    if (GetDiskFreeSpaceExW(pathw, &available, &total, &total_free) == 0) {
        return null;
    }

    // No reserved-for-root blocks on Windows; the gap between total free
    // and free-to-caller is the closest analogue (user quota).
    return .{
        .total = total,
        .available = available,
        .reserved = total_free -| available,
    };
}
