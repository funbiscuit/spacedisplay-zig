//! Library root re-exporting the public API.

const std = @import("std");

pub const Scanner = @import("Scanner.zig");
pub const Tree = @import("Tree.zig");
pub const StringPool = @import("StringPool.zig");
pub const queue = @import("queue.zig");
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
