//! ModalHost tests: compositing, stacking, focus hand-off and the shield.
//!
//! The golden tests pin each stacking step with the same fixtures: idle
//! base, one modal over it, then a second one on top — so the diff between
//! `one_modal` and `stacked` is exactly the effect of the extra level.

const std = @import("std");
const spacedisplay = @import("spacedisplay");

const fixtures = @import("fixtures.zig");
const harness = @import("harness.zig");
const snapshot = @import("snapshot.zig");

const Box = fixtures.Box;
const ModalHost = spacedisplay.ui.ModalHost;

const gpa = std.testing.allocator;

fn makeHost(base: *Box) ModalHost {
    var host = ModalHost.init(gpa);
    host.setBase(base.widget(), base.widget());
    return host;
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

    const focused = try fixtures.pushFocus(&host, .{ .widget = modal.widget() });
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

    _ = try fixtures.pushFocus(&host, .{ .widget = big.widget() });
    _ = try fixtures.pushFocus(&host, .{ .widget = small.widget() });

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

    var focused = (try fixtures.pushFocus(&host, .{ .widget = first.widget() })).?;
    try std.testing.expect(focused.eql(first.widget()));
    focused = (try fixtures.pushFocus(&host, .{ .widget = second.widget() })).?;
    try std.testing.expect(focused.eql(second.widget()));

    focused = (try fixtures.popFocus(&host)).?;
    try std.testing.expect(focused.eql(first.widget()));
    focused = (try fixtures.popFocus(&host)).?;
    try std.testing.expect(focused.eql(base.widget()));

    // Popping an empty stack does nothing and asks for no focus.
    try std.testing.expect((try fixtures.popFocus(&host)) == null);
    try std.testing.expect(!host.active());
}

test "shield pops on outside press and consumes every mouse event" {
    var base = Box{ .width = 10, .height = 3, .grapheme = "a" };
    var modal = Box{ .width = 4, .height = 1, .grapheme = "M" };
    var host = makeHost(&base);
    defer host.deinit();
    _ = try fixtures.pushFocus(&host, .{ .widget = modal.widget() });
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
    _ = try fixtures.pushFocus(&host, .{ .widget = modal.widget(), .dismiss_on_click_outside = false });
    const shield = host.shieldWidget();

    var d = try harness.send(gpa, shield, harness.mouse(.left, .press, 0, 0));
    defer d.deinit(gpa);
    try std.testing.expect(d.consume_event);
    try std.testing.expect(host.active());
}
