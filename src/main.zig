//! Executable entry point.
//! All application code lives in the spacedisplay library module.

const std = @import("std");
const spacedisplay = @import("spacedisplay");

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = spacedisplay.logging.myLogFn,
};

pub const panic = spacedisplay.vaxis.panic_handler;

pub fn main(init: std.process.Init) !u8 {
    spacedisplay.logging.init(init.io);
    return spacedisplay.cli.run(init);
}
