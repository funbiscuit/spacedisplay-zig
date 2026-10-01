//! ProgressBar golden test: stacked size segments.

const std = @import("std");
const spacedisplay = @import("spacedisplay");

const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");

const gpa = std.testing.allocator;

test "ProgressBar renders stacked sizes" {
    var bar: spacedisplay.ui.ProgressBar = .{
        .stats = .{
            .total_dirs = 2,
            .total_files = 10,
            .scanned_size = 1500,
            .current_dir_size = 500,
            .unknown_size = 300,
            .available_size = 2000,
            .is_mount_point = true,
        },
    };
    const widget = bar.widget();

    const rendered = try harness.draw(gpa, widget, 80, 1);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("progress_bar/stacked", rendered);
}
