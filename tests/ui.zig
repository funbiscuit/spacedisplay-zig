//! UI end-to-end tests: widgets driven through the headless harness.

test {
    _ = @import("ui/files_view_test.zig");
    _ = @import("ui/app_view_test.zig");
    _ = @import("ui/progress_bar_test.zig");
}
