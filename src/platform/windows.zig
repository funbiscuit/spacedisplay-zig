//! Windows backend: volume serial numbers identify volumes (the role
//! st_dev plays on POSIX), disk space comes from GetDiskFreeSpaceExW.

const std = @import("std");
const win32 = std.os.windows;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Space = struct { total: u64, available: u64, reserved: u64 };

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
