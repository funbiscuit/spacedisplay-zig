//! Shared fixtures for CLI e2e tests.

const std = @import("std");

const gpa = std.testing.allocator;
const io = std.testing.io;

pub const PrintFixture = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,

    /// 50 B file at the root, a/ with a 100 B file, a/b/ with a 200 B file.
    /// Dump sizes: root 350 B, a/ 300 B, a/b/ 200 B.
    pub fn create() !PrintFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try writeFile(tmp.dir, "root50.bin", 50);
        try writeFile(tmp.dir, "a/one.bin", 100);
        try writeFile(tmp.dir, "a/b/two.bin", 200);
        const path = try tmpPath(&tmp);
        errdefer gpa.free(path);
        return .{ .tmp = tmp, .path = path };
    }

    pub fn destroy(self: *PrintFixture) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

/// Absolute path of a testing.TmpDir without realpath: cwd plus the
/// `.zig-cache/tmp` prefix that tmpDir creates under.
fn tmpPath(tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);
    return std.fs.path.join(gpa, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
}

fn writeFile(dir: std.Io.Dir, sub_path: []const u8, size: usize) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    var f = try dir.createFile(io, sub_path, .{});
    defer f.close(io);
    var buf = [_]u8{0} ** 4096;
    var left = size;
    while (left > 0) {
        const n = @min(left, buf.len);
        try f.writeStreamingAll(io, buf[0..n]);
        left -= n;
    }
}
