//! Shared fixtures for UI tests.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const spacedisplay = @import("spacedisplay");
const TestCtx = @import("TestCtx.zig").TestCtx;

const gpa = std.testing.allocator;

const Allocator = std.mem.Allocator;

const ModalHost = spacedisplay.ui.ModalHost;

/// A solid rectangle of one grapheme: minimal stand-in for a real view or
/// modal when a test needs an arbitrary widget shape.
pub const Box = struct {
    width: u16,
    height: u16,
    grapheme: []const u8,
    style: vaxis.Style = .{},

    pub fn widget(self: *Box) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEvent,
            .drawFn = typeErasedDraw,
        };
    }

    fn typeErasedEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        _ = ptr;
        _ = ctx;
        _ = event;
    }

    fn typeErasedDraw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Box = @ptrCast(@alignCast(ptr));
        const surface = try vxfw.Surface.init(
            ctx.arena,
            self.widget(),
            .{ .width = self.width, .height = self.height },
        );
        @memset(surface.buffer, .{ .char = .{ .grapheme = self.grapheme }, .style = self.style });
        return surface;
    }
};

/// Runs push (or pop) with a real EventContext and returns the widget the
/// host asked to focus, if any.
pub fn pushFocus(host: *ModalHost, entry: ModalHost.Entry) !?vxfw.Widget {
    var event_ctx = vxfw.EventContext{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer event_ctx.cmds.deinit(gpa);
    try host.push(&event_ctx, entry);
    return focusFrom(&event_ctx);
}

pub fn popFocus(host: *ModalHost) !?vxfw.Widget {
    var event_ctx = vxfw.EventContext{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer event_ctx.cmds.deinit(gpa);
    try host.pop(&event_ctx);
    return focusFrom(&event_ctx);
}

pub fn focusFrom(event_ctx: *vxfw.EventContext) ?vxfw.Widget {
    var focused: ?vxfw.Widget = null;
    for (event_ctx.cmds.items) |cmd| {
        switch (cmd) {
            .request_focus => |w| focused = w,
            else => {},
        }
    }
    return focused;
}

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
