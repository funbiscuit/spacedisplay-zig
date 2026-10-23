//! FilesView golden tests: navigation, scrolling and the scan spinner.

const std = @import("std");
const vaxis = @import("vaxis");
const spacedisplay = @import("spacedisplay");

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

test "delete key confirms before Ctx sees a request" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    var host = spacedisplay.ui.ModalHost.init(gpa);
    defer host.deinit();
    host.setBase(view.widget(), view.widget());
    view.setModalHost(&host);
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    // selection sits on "big": the dialog opens, nothing is queued yet
    d = try harness.send(gpa, widget, harness.keyPress(Key.delete));
    d.deinit(gpa);
    try std.testing.expect(host.active());
    try std.testing.expectEqual(@as(usize, 0), ctx.delete_requests.items.len);

    // 'n' cancels: the dialog closes without a request
    d = try harness.send(gpa, view._confirm_dialog.?.widget(), harness.keyPress('n'));
    d.deinit(gpa);
    try std.testing.expect(!host.active());
    try std.testing.expectEqual(@as(usize, 0), ctx.delete_requests.items.len);

    // 'y' confirms: one request for the pressed-time dir and entry name
    d = try harness.send(gpa, widget, harness.keyPress(Key.delete));
    d.deinit(gpa);
    d = try harness.send(gpa, view._confirm_dialog.?.widget(), harness.keyPress('y'));
    d.deinit(gpa);
    try std.testing.expect(!host.active());
    try std.testing.expectEqual(@as(usize, 1), ctx.delete_requests.items.len);
    try std.testing.expect(view._opened_dir_id.eql(ctx.delete_requests.items[0].parent));
    try std.testing.expectEqualStrings("big", ctx.delete_requests.items[0].name);
}

test "delete request carries the dir that was open at key-press time" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    var host = spacedisplay.ui.ModalHost.init(gpa);
    defer host.deinit();
    host.setBase(view.widget(), view.widget());
    view.setModalHost(&host);
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    // open "sub"; its only entry is "sub.bin"
    d = try harness.send(gpa, widget, harness.keyPress(Key.down));
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.keyPress(Key.enter));
    d.deinit(gpa);
    const sub_id = view._opened_dir_id;

    d = try harness.send(gpa, widget, harness.keyPress(Key.delete));
    d.deinit(gpa);
    d = try harness.send(gpa, view._confirm_dialog.?.widget(), harness.keyPress('y'));
    d.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), ctx.delete_requests.items.len);
    try std.testing.expect(sub_id.eql(ctx.delete_requests.items[0].parent));
    try std.testing.expectEqualStrings("sub.bin", ctx.delete_requests.items[0].name);
}

test "delete key ignores the parent row" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    var host = spacedisplay.ui.ModalHost.init(gpa);
    defer host.deinit();
    host.setBase(view.widget(), view.widget());
    view.setModalHost(&host);
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);

    // selection starts on "." (index 0): no dialog, no request
    view._selected_index = 0;
    d = try harness.send(gpa, widget, harness.keyPress(Key.delete));
    d.deinit(gpa);
    try std.testing.expect(!host.active());
    try std.testing.expectEqual(@as(usize, 0), ctx.delete_requests.items.len);
}

test "deletion failures surface as a toast that expires" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);

    // the worker recorded a failure; the next tick picks it up once
    ctx.error_message = "Failed to delete 'root.txt': AccessDenied";
    d = try harness.send(gpa, widget, harness.tick);
    try std.testing.expect(d.redraw);
    d.deinit(gpa);
    try std.testing.expect(view._toast != null);
    try std.testing.expect(ctx.error_message == null);

    {
        const rendered = try harness.draw(gpa, widget, 80, 12);
        defer rendered.deinit(gpa);
        try snapshot.expectGolden("files_view/toast", rendered);
    }

    // the fake clock moves past the expiry; the next tick drops the
    // toast and the view renders like the plain listing again
    ctx.now_ms = 4000;
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);
    try std.testing.expect(view._toast == null);
    {
        const rendered = try harness.draw(gpa, widget, 80, 12);
        defer rendered.deinit(gpa);
        try snapshot.expectGolden("files_view/basic", rendered);
    }
}

test "any key press clears the toast" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);

    ctx.error_message = "Failed to delete 'root.txt': AccessDenied";
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);
    try std.testing.expect(view._toast != null);

    // the key still does its own job (selection moves); the toast goes
    d = try harness.send(gpa, widget, harness.keyPress(Key.down));
    try std.testing.expect(d.redraw);
    d.deinit(gpa);
    try std.testing.expect(view._toast == null);
    try std.testing.expectEqual(@as(usize, 2), view._selected_index);
}

test "FilesView falls back to the parent when the opened dir is deleted" {
    var ctx = try fixtures.makeCtx();
    defer ctx.deinit(gpa);
    var view = fixtures.makeView(&ctx);
    defer view.deinit();
    const widget = view.widget();

    var d = try harness.send(gpa, widget, .init);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.tick);
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.keyPress(Key.down));
    d.deinit(gpa);
    d = try harness.send(gpa, widget, harness.keyPress(Key.enter));
    d.deinit(gpa);
    try std.testing.expect(!view._opened_dir_id.eql(.root));

    // "sub" is deleted outside the app; the next update must walk us back
    // out to the root listing instead of showing stale content
    ctx.missing_paths = &.{"/base/sub"};
    ctx.now_ms = 1000; // push past the update throttle

    d = try harness.send(gpa, widget, harness.tick);
    try std.testing.expect(d.redraw);
    d.deinit(gpa);

    try std.testing.expect(view._opened_dir_id.eql(.root));
    try std.testing.expectEqual(@as(usize, 0), view._selected_index);
    // fresh root listing: ".", "big", "sub", "root.txt"
    try std.testing.expectEqual(@as(usize, 4), view._entries.items.len);
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
