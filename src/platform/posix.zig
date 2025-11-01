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
