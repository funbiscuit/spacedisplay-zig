//! Library root re-exporting the public API.

const std = @import("std");

pub const core = @import("core.zig");
pub const runtime = @import("runtime.zig");
pub const platform = @import("platform.zig");
pub const cli = @import("cli.zig");
pub const logging = @import("logging.zig");
pub const ui = @import("ui.zig");

/// Re-exported for consumers of the library: public widget signatures use
/// vaxis types, and the executable needs it for the panic handler.
pub const vaxis = @import("vaxis");

test {
    std.testing.refAllDecls(@This());
}
