//! UI namespace: vaxis vxfw widgets live here.

const std = @import("std");

pub const AppView = @import("ui/app_view.zig").AppView;
pub const FilesView = @import("ui/files_view.zig").FilesView;
pub const ProgressBar = @import("ui/ProgressBar.zig");
pub const utils = @import("ui/utils.zig");

test {
    std.testing.refAllDecls(@This());
}
