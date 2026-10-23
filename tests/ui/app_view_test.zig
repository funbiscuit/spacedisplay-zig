//! AppView golden test: border, file list and progress bar composition.

const std = @import("std");
const vaxis = @import("vaxis");
const spacedisplay = @import("spacedisplay");

const TestCtx = @import("TestCtx.zig").TestCtx;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");

const AppView = spacedisplay.ui.AppView;

const gpa = std.testing.allocator;

test "AppView composes border, files and progress bar" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var app = AppView(TestCtx).init(gpa, &ctx);
    defer app.deinit();
    const widget = app.rootWidget();

    // like the real app: init focuses the file list, ticks go to it
    var d = try harness.send(gpa, widget, .init);
    const focused = d.focused.?;
    d.deinit(gpa);
    d = try harness.send(gpa, focused, harness.tick);
    d.deinit(gpa);

    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("app_view/compose", rendered);
}

test "AppView quits on ctrl+c in capture phase" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var app = AppView(TestCtx).init(gpa, &ctx);
    defer app.deinit();

    var d = try harness.sendCapture(gpa, app.widget(), harness.keyPressMods('c', .{ .ctrl = true }));
    defer d.deinit(gpa);
    try std.testing.expect(d.quit);
}

test "AppView renders a modal over the whole view" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var app = AppView(TestCtx).init(gpa, &ctx);
    defer app.deinit();
    const widget = app.rootWidget();

    var modal = fixtures.Box{ .width = 40, .height = 7, .grapheme = "M", .style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 7 } } };
    const focused = try fixtures.pushFocus(app.modalHost(), .{ .widget = modal.widget() });
    try std.testing.expect(focused.?.eql(modal.widget()));

    // ctrl+c still quits while the modal holds the focus: the host forwards
    // capture events to the composited-away base view.
    var d = try harness.sendCapture(gpa, widget, harness.keyPressMods('c', .{ .ctrl = true }));
    try std.testing.expect(d.quit);
    d.deinit(gpa);

    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("app_view/modal", rendered);
}

test "Delete key opens the confirm dialog over the whole view" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var app = AppView(TestCtx).init(gpa, &ctx);
    defer app.deinit();
    const widget = app.rootWidget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, app._files_view.widget(), harness.tick);
    d.deinit(gpa);

    // selection starts on "big"; the Delete key opens the real dialog on
    // the app's modal host, and nothing is deleted before confirmation
    d = try harness.send(gpa, app._files_view.widget(), harness.keyPress(vaxis.Key.delete));
    d.deinit(gpa);
    try std.testing.expect(app.modalHost().active());
    try std.testing.expectEqual(@as(usize, 0), ctx.delete_requests.items.len);

    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("app_view/delete_dialog", rendered);
}
