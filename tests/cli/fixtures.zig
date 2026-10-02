//! Shared fixtures for CLI e2e tests.

const std = @import("std");

const gpa = std.testing.allocator;

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
        const path = try tmp.dir.realpathAlloc(gpa, ".");
        errdefer gpa.free(path);
        return .{ .tmp = tmp, .path = path };
    }

    pub fn destroy(self: *PrintFixture) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

fn writeFile(dir: std.fs.Dir, sub_path: []const u8, size: usize) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.makePath(parent);
    var f = try dir.createFile(sub_path, .{});
    defer f.close();
    var buf = [_]u8{0} ** 4096;
    var left = size;
    while (left > 0) {
        const n = @min(left, buf.len);
        try f.writeAll(buf[0..n]);
        left -= n;
    }
}
