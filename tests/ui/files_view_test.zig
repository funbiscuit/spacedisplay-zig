//! FilesView golden tests: navigation, scrolling and the scan spinner.

const std = @import("std");
const vaxis = @import("vaxis");

const TestCtx = @import("TestCtx.zig").TestCtx;
const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");

const gpa = std.testing.allocator;

const Key = vaxis.Key;

test "FilesView renders the listing" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var init_dispatch = try harness.send(gpa, widget, .init);
    init_dispatch.deinit(gpa);
    var tick_dispatch = try harness.send(gpa, widget, harness.tick);
    try std.testing.expect(tick_dispatch.redraw);
    tick_dispatch.deinit(gpa);

    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("files_view/basic", rendered);
}

test "FilesView moves selection with keys and navigates dirs" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    // down: selection moves to "sub"
    d = try harness.send(gpa, widget, harness.keyPress(Key.down));
    try std.testing.expect(d.redraw);
    d.deinit(gpa);
    {
        const rendered = try harness.draw(gpa, widget, 80, 12);
        defer rendered.deinit(gpa);
        try snapshot.expectGolden("files_view/selected_sub", rendered);
    }

    // enter: open "sub" (shows its file from the fake disk)
    d = try harness.send(gpa, widget, harness.keyPress(Key.enter));
    d.deinit(gpa);
    {
        const rendered = try harness.draw(gpa, widget, 80, 12);
        defer rendered.deinit(gpa);
        try snapshot.expectGolden("files_view/opened_sub", rendered);
    }

    // escape: back to root with "sub" selected again
    d = try harness.send(gpa, widget, harness.keyPress(Key.escape));
    d.deinit(gpa);
    {
        const rendered = try harness.draw(gpa, widget, 80, 12);
        defer rendered.deinit(gpa);
        try snapshot.expectGolden("files_view/selected_sub", rendered);
    }
}

test "FilesView opens a directory with a mouse click" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    // click on the second row ("big")
    d = try harness.send(gpa, widget, harness.mouse(.left, .release, 1, 5));
    d.deinit(gpa);
    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("files_view/opened_big", rendered);
}

test "FilesView scrolls long listings" {
    var name_bufs: [20][8]u8 = undefined;
    var listing: [20]TestCtx.DirEntry = undefined;
    for (0..20) |i| {
        const name = std.fmt.bufPrint(&name_bufs[i], "dir{d:0>2}", .{i}) catch unreachable;
        listing[i] = .{
            .name = name,
            .size = 0,
            .kind = .directory,
            .can_scan = true,
        };
    }
    var ctx = try TestCtx.init(gpa, &.{.{ .path = "/base", .entries = &listing }});
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    // jump to the end: the list must scroll to keep the selection visible
    d = try harness.send(gpa, widget, harness.keyPress(Key.end));
    d.deinit(gpa);
    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("files_view/scrolled_end", rendered);
}

test "FilesView shows a spinner for the directory being scanned" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);

    // pretend the scanner is working inside "sub" (id resolved via listDir)
    var entries = try ctx.listDir(gpa, .root);
    defer TestCtx.deinitListDir(gpa, &entries);
    const sub_id = for (entries.items) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.name, "sub")) break entry.id.?;
    } else return error.MissingDir;
    ctx.scanned_child = sub_id;
    ctx.now_ms = 1234;

    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("files_view/spinner", rendered);
}

test "FilesView highlights the hovered row without moving the selection" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    // motion over the third row ("sub"): the bold highlight follows the
    // mouse while the selection (and the ">" cursor) stays on "big"
    d = try harness.send(gpa, widget, harness.mouse(.none, .motion, 2, 5));
    try std.testing.expect(d.redraw);
    d.deinit(gpa);
    {
        const rendered = try harness.draw(gpa, widget, 80, 12);
        defer rendered.deinit(gpa);
        try snapshot.expectGolden("files_view/hovered", rendered);
    }

    // enter still opens the selected entry ("big"), not the hovered one
    d = try harness.send(gpa, widget, harness.keyPress(Key.enter));
    d.deinit(gpa);
    {
        const rendered = try harness.draw(gpa, widget, 80, 12);
        defer rendered.deinit(gpa);
        try snapshot.expectGolden("files_view/opened_big", rendered);
    }
}

test "FilesView drops the hover highlight on keyboard navigation" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    d = try harness.send(gpa, widget, harness.mouse(.none, .motion, 2, 5));
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.keyPress(Key.down));
    try std.testing.expect(d.redraw);
    d.deinit(gpa);
    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("files_view/hover_dropped", rendered);
}

test "FilesView wheel scrolls without moving the selection" {
    var name_bufs: [20][8]u8 = undefined;
    var listing: [20]TestCtx.DirEntry = undefined;
    for (0..20) |i| {
        const name = std.fmt.bufPrint(&name_bufs[i], "dir{d:0>2}", .{i}) catch unreachable;
        listing[i] = .{
            .name = name,
            .size = 0,
            .kind = .directory,
            .can_scan = true,
        };
    }
    var ctx = try TestCtx.init(gpa, &.{.{ .path = "/base", .entries = &listing }});
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    // scroll down two notches: the highlight tracks the row under the
    // cursor while the selection (">" cursor) may leave the view
    d = try harness.send(gpa, widget, harness.mouse(.none, .motion, 3, 5));
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.mouse(.wheel_down, .press, 3, 5));
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.mouse(.wheel_down, .press, 3, 5));
    d.deinit(gpa);
    {
        const rendered = try harness.draw(gpa, widget, 80, 12);
        defer rendered.deinit(gpa);
        try snapshot.expectGolden("files_view/wheel_scrolled", rendered);
    }

    // keyboard navigation brings the untouched selection back into view
    d = try harness.send(gpa, widget, harness.keyPress(Key.up));
    d.deinit(gpa);
    const rendered = try harness.draw(gpa, widget, 80, 12);
    defer rendered.deinit(gpa);
    try snapshot.expectGolden("files_view/wheel_return", rendered);
}
