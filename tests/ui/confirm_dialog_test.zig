//! ConfirmDialog tests: rendering, result keys and teardown safety.

const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const spacedisplay = @import("spacedisplay");

const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");

const Box = fixtures.Box;
const ConfirmDialog = spacedisplay.ui.ConfirmDialog;
const ModalHost = spacedisplay.ui.ModalHost;

const gpa = std.testing.allocator;

const Events = struct {
    confirmed: usize = 0,
    cancelled: usize = 0,

    fn onResult(userdata: ?*anyopaque, result: ConfirmDialog.Result) anyerror!void {
        const self: *Events = @ptrCast(@alignCast(userdata.?));
        switch (result) {
            .confirmed => self.confirmed += 1,
            .cancelled => self.cancelled += 1,
        }
    }
};

fn makeHost(base: *Box) ModalHost {
    var host = ModalHost.init(gpa);
    host.setBase(base.widget(), base.widget());
    return host;
}

test "dialog floats over the dimmed base" {
    var base = Box{ .width = 44, .height = 10, .grapheme = "a", .style = .{ .fg = .{ .index = 3 } } };
    var host = makeHost(&base);
    defer host.deinit();
    var events = Events{};
    var dialog = ConfirmDialog.init(gpa, &host);
    defer dialog.deinit();

    var ectx = vxfw.EventContext{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer ectx.cmds.deinit(gpa);
    try dialog.show(&ectx, "Confirm Deletion", "Delete 'big.bin'?", &events, Events.onResult);

    // Showing pushed the dialog and focused it.
    try std.testing.expect(host.active());
    const focused = fixtures.focusFrom(&ectx);
    try std.testing.expect(focused.?.eql(dialog.widget()));

    const rendered = try harness.draw(gpa, host.widget(), 44, 10);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("confirm_dialog/shown", rendered);
    try std.testing.expectEqual(@as(usize, 0), events.confirmed);
    try std.testing.expectEqual(@as(usize, 0), events.cancelled);
}

test "y confirms, n and escape cancel, other keys are ignored" {
    var base = Box{ .width = 20, .height = 5, .grapheme = "a" };
    var host = makeHost(&base);
    defer host.deinit();
    var events = Events{};
    var dialog = ConfirmDialog.init(gpa, &host);
    defer dialog.deinit();

    var ectx = vxfw.EventContext{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer ectx.cmds.deinit(gpa);
    try dialog.show(&ectx, "t", "q", &events, Events.onResult);
    try std.testing.expectError(error.AlreadyShowing, dialog.show(&ectx, "t", "q", &events, Events.onResult));

    var d = try harness.send(gpa, dialog.widget(), harness.keyPress('y'));
    try std.testing.expect(d.consume_event);
    d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), events.confirmed);
    try std.testing.expect(!host.active());

    // The dialog can be shown again after reporting.
    try dialog.show(&ectx, "t", "q", &events, Events.onResult);
    d = try harness.send(gpa, dialog.widget(), harness.keyPress('N'));
    try std.testing.expect(d.consume_event);
    d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), events.cancelled);

    try dialog.show(&ectx, "t", "q", &events, Events.onResult);
    d = try harness.send(gpa, dialog.widget(), harness.keyPress('x'));
    try std.testing.expect(!d.consume_event);
    d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), events.confirmed);
    try std.testing.expectEqual(@as(usize, 1), events.cancelled);
    try std.testing.expect(host.active());

    d = try harness.send(gpa, dialog.widget(), harness.keyPress(@import("vaxis").Key.escape));
    try std.testing.expect(d.consume_event);
    d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), events.cancelled);
    try std.testing.expect(!host.active());
}

test "mouse events are consumed without affecting the dialog" {
    var base = Box{ .width = 20, .height = 5, .grapheme = "a" };
    var host = makeHost(&base);
    defer host.deinit();
    var events = Events{};
    var dialog = ConfirmDialog.init(gpa, &host);
    defer dialog.deinit();

    var ectx = vxfw.EventContext{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer ectx.cmds.deinit(gpa);
    try dialog.show(&ectx, "t", "q", &events, Events.onResult);

    var d = try harness.send(gpa, dialog.widget(), harness.mouse(.left, .press, 2, 10));
    try std.testing.expect(d.consume_event);
    d.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), events.confirmed);
    try std.testing.expectEqual(@as(usize, 0), events.cancelled);
    try std.testing.expect(host.active());
}

test "deinit while shown reports cancelled and frees the context" {
    const Payload = struct {};

    const Free = struct {
        fn onResult(userdata: ?*anyopaque, result: ConfirmDialog.Result) anyerror!void {
            try std.testing.expectEqual(ConfirmDialog.Result.cancelled, result);
            gpa.destroy(@as(*Payload, @ptrCast(@alignCast(userdata.?))));
        }
    };

    var base = Box{ .width = 20, .height = 5, .grapheme = "a" };
    var host = makeHost(&base);
    defer host.deinit();
    var dialog = ConfirmDialog.init(gpa, &host);

    const payload = try gpa.create(Payload);
    var ectx = vxfw.EventContext{ .io = std.testing.io, .alloc = gpa, .cmds = .empty };
    defer ectx.cmds.deinit(gpa);
    try dialog.show(&ectx, "t", "q", payload, Free.onResult);
    // The callback frees the payload; the leak detector would fail the test
    // if deinit skipped it.
    dialog.deinit();
}
