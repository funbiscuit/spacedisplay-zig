//! ModalHost tests: compositing, stacking, focus hand-off and the shield.
//!
//! The golden tests pin each stacking step with the same fixtures: idle
//! base, one modal over it, then a second one on top — so the diff between
//! `one_modal` and `stacked` is exactly the effect of the extra level.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const spacedisplay = @import("spacedisplay");

const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");

const ModalHost = spacedisplay.ui.ModalHost;

const gpa = std.testing.allocator;

/// A solid rectangle of one grapheme: minimal stand-in for a real view/modal.
const Box = struct {
    width: u16,
    height: u16,
    grapheme: []const u8,
    style: vaxis.Style = .{},

    fn widget(self: *Box) vxfw.Widget {
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

const Allocator = std.mem.Allocator;

fn makeHost(base: *Box) ModalHost {
    var host = ModalHost.init(gpa);
    host.setBase(base.widget(), base.widget());
    return host;
}

/// Runs push (or pop) with a real EventContext and returns the widget the
/// host asked to focus, if any.
fn pushFocus(host: *ModalHost, entry: ModalHost.Entry) !?vxfw.Widget {
    var event_ctx = vxfw.EventContext{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer event_ctx.cmds.deinit(gpa);
    try host.push(&event_ctx, entry);
    return focusFrom(&event_ctx);
}

fn popFocus(host: *ModalHost) !?vxfw.Widget {
    var event_ctx = vxfw.EventContext{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer event_ctx.cmds.deinit(gpa);
    try host.pop(&event_ctx);
    return focusFrom(&event_ctx);
}

fn focusFrom(event_ctx: *vxfw.EventContext) ?vxfw.Widget {
    var focused: ?vxfw.Widget = null;
    for (event_ctx.cmds.items) |cmd| {
        switch (cmd) {
            .request_focus => |w| focused = w,
            else => {},
        }
    }
    return focused;
}

test "idle host renders the base view unchanged" {
    var base = Box{ .width = 20, .height = 4, .grapheme = "a" };
    var host = makeHost(&base);
    defer host.deinit();

    const via_host = try harness.draw(gpa, host.widget(), 20, 4);
    defer via_host.deinit(gpa);
    const direct = try harness.draw(gpa, base.widget(), 20, 4);
    defer direct.deinit(gpa);
    try std.testing.expectEqualStrings(direct.text, via_host.text);
    try snapshot.expectGolden("modal_host/idle", via_host);
}

test "one modal dims the base and centers" {
    var base = Box{ .width = 30, .height = 8, .grapheme = "a", .style = .{ .fg = .{ .index = 3 } } };
    var modal = Box{ .width = 24, .height = 6, .grapheme = "B", .style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } } };
    var host = makeHost(&base);
    defer host.deinit();

    const focused = try pushFocus(&host, .{ .widget = modal.widget() });
    try std.testing.expect(focused.?.eql(modal.widget()));

    const rendered = try harness.draw(gpa, host.widget(), 30, 8);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("modal_host/one_modal", rendered);
}

test "stacked modals keep the lower one visible and dimmed" {
    var base = Box{ .width = 30, .height = 8, .grapheme = "a", .style = .{ .fg = .{ .index = 3 } } };
    var big = Box{ .width = 24, .height = 6, .grapheme = "B", .style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } } };
    var small = Box{ .width = 12, .height = 3, .grapheme = "s", .style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 4 } } };
    var host = makeHost(&base);
    defer host.deinit();

    _ = try pushFocus(&host, .{ .widget = big.widget() });
    _ = try pushFocus(&host, .{ .widget = small.widget() });

    const rendered = try harness.draw(gpa, host.widget(), 30, 8);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("modal_host/stacked", rendered);
}

test "push focuses the modal, pop walks back and restores the base" {
    var base = Box{ .width = 10, .height = 3, .grapheme = "a" };
    var first = Box{ .width = 4, .height = 1, .grapheme = "1" };
    var second = Box{ .width = 4, .height = 1, .grapheme = "2" };
    var host = makeHost(&base);
    defer host.deinit();

    var focused = (try pushFocus(&host, .{ .widget = first.widget() })).?;
    try std.testing.expect(focused.eql(first.widget()));
    focused = (try pushFocus(&host, .{ .widget = second.widget() })).?;
    try std.testing.expect(focused.eql(second.widget()));

    focused = (try popFocus(&host)).?;
    try std.testing.expect(focused.eql(first.widget()));
    focused = (try popFocus(&host)).?;
    try std.testing.expect(focused.eql(base.widget()));

    // Popping an empty stack does nothing and asks for no focus.
    try std.testing.expect((try popFocus(&host)) == null);
    try std.testing.expect(!host.active());
}

test "shield pops on outside press and consumes every mouse event" {
    var base = Box{ .width = 10, .height = 3, .grapheme = "a" };
    var modal = Box{ .width = 4, .height = 1, .grapheme = "M" };
    var host = makeHost(&base);
    defer host.deinit();
    _ = try pushFocus(&host, .{ .widget = modal.widget() });
    const shield = host.shieldWidget();

    // Motion is swallowed without dismissing.
    var d = try harness.send(gpa, shield, harness.mouse(.none, .motion, 0, 0));
    try std.testing.expect(d.consume_event);
    d.deinit(gpa);
    try std.testing.expect(host.active());

    // A press bubbling up from the modal never dismisses.
    d = try harness.sendPhase(gpa, shield, harness.mouse(.left, .press, 0, 0), .bubbling);
    try std.testing.expect(d.consume_event);
    d.deinit(gpa);
    try std.testing.expect(host.active());

    // A press aimed at the shield pops the top modal.
    d = try harness.send(gpa, shield, harness.mouse(.left, .press, 0, 0));
    try std.testing.expect(d.consume_event);
    d.deinit(gpa);
    try std.testing.expect(!host.active());
}

test "shield keeps a modal that opted out of outside dismissal" {
    var base = Box{ .width = 10, .height = 3, .grapheme = "a" };
    var modal = Box{ .width = 4, .height = 1, .grapheme = "M" };
    var host = makeHost(&base);
    defer host.deinit();
    _ = try pushFocus(&host, .{ .widget = modal.widget(), .dismiss_on_click_outside = false });
    const shield = host.shieldWidget();

    var d = try harness.send(gpa, shield, harness.mouse(.left, .press, 0, 0));
    defer d.deinit(gpa);
    try std.testing.expect(d.consume_event);
    try std.testing.expect(host.active());
}
