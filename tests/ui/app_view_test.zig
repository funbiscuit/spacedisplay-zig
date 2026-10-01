//! AppView golden test: border, file list and progress bar composition.

const std = @import("std");
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
    var app = try AppView(TestCtx).init(gpa, &ctx);
    defer app.deinit();
    const widget = app.widget();

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
