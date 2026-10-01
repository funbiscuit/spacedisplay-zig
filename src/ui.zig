//! UI namespace: vaxis vxfw widgets live here.

const std = @import("std");

pub const AppView = @import("ui/AppView.zig");
pub const FilesView = @import("ui/FilesView.zig");
pub const ProgressBar = @import("ui/ProgressBar.zig");
pub const utils = @import("ui/utils.zig");

test {
    std.testing.refAllDecls(@This());
}
