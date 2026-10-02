//! End-to-end tests (UI, CLI). Runs against the public API only.

test {
    _ = @import("ui.zig");
    _ = @import("cli.zig");
}
