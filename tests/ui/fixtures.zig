//! Shared fixtures for UI tests.

const std = @import("std");
const spacedisplay = @import("spacedisplay");
const TestCtx = @import("TestCtx.zig").TestCtx;

const gpa = std.testing.allocator;

/// Two subdirectories with one file each, plus a root file.
pub fn makeCtx() !TestCtx {
    return TestCtx.init(gpa, &.{
        .{ .path = "/base", .entries = &.{
            .{ .name = "big", .size = 0, .kind = .directory, .can_scan = true },
            .{ .name = "sub", .size = 0, .kind = .directory, .can_scan = true },
            .{ .name = "root.txt", .size = 40, .kind = .file },
        } },
        .{ .path = "/base/big", .entries = &.{
            .{ .name = "big.bin", .size = 1000, .kind = .file },
        } },
        .{ .path = "/base/sub", .entries = &.{
            .{ .name = "sub.bin", .size = 300, .kind = .file },
        } },
    });
}

pub fn makeView(ctx: *TestCtx) spacedisplay.ui.FilesView(TestCtx) {
    return spacedisplay.ui.FilesView(TestCtx).init(gpa, ctx);
}
