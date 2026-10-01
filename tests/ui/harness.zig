//! Headless UI test harness: draws widgets to a text grid and dispatches
//! synthetic key / mouse / tick events, all without a terminal.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;

pub const Rendered = struct {
    /// Plain text, one line per row, trailing blanks trimmed.
    text: []const u8,
    /// The same rows with SGR escapes for cell styles (see toAnsi).
    ansi: []const u8,

    pub fn deinit(self: *const Rendered, gpa: Allocator) void {
        gpa.free(self.text);
        gpa.free(self.ansi);
    }
};

/// Renders a widget to both golden formats in one draw pass.
pub fn draw(gpa: Allocator, widget: vxfw.Widget, width: u16, height: u16) !Rendered {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var screen = try vaxis.Screen.init(gpa, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = &screen,
    };

    const surface = try widget.draw(.{
        .arena = arena.allocator(),
        .min = .{},
        .max = .{ .width = width, .height = height },
        .cell_size = .{ .width = 8, .height = 16 },
    });
    surface.render(win, undefined);

    const text = try toText(gpa, &screen);
    errdefer gpa.free(text);
    const ansi = try toAnsi(gpa, &screen);
    return .{ .text = text, .ansi = ansi };
}

fn toText(gpa: Allocator, screen: *const vaxis.Screen) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (0..screen.height) |row| {
        var end: usize = out.items.len;
        for (0..screen.width) |col| {
            const grapheme = screen.buf[row * screen.width + col].char.grapheme;
            try out.appendSlice(gpa, grapheme);
            if (!std.mem.eql(u8, grapheme, " ")) end = out.items.len;
        }
        out.shrinkRetainingCapacity(end);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// A cell that renders as nothing: a plain space with the default style.
/// Styled blanks (e.g. progress bar segments) are NOT blank.
fn isBlank(cell: vaxis.Cell) bool {
    return cell.style.eql(.{}) and std.mem.eql(u8, cell.char.grapheme, " ");
}

fn toAnsi(gpa: Allocator, screen: *const vaxis.Screen) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (0..screen.height) |row| {
        var end: usize = 0;
        for (0..screen.width) |col| {
            if (!isBlank(screen.buf[row * screen.width + col])) end = col + 1;
        }

        var cur: ?vaxis.Style = null;
        for (0..end) |col| {
            const cell = screen.buf[row * screen.width + col];
            if (cur == null or !cur.?.eql(cell.style)) {
                try writeSgr(gpa, &out, cell.style);
                cur = cell.style;
            }
            try out.appendSlice(gpa, cell.char.grapheme);
        }
        if (end > 0) try out.appendSlice(gpa, "\x1b[0m");
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// Emits a full SGR sequence (from default) for the style.
fn writeSgr(gpa: Allocator, out: *std.ArrayList(u8), style: vaxis.Style) !void {
    try out.appendSlice(gpa, "\x1b[0");
    if (style.bold) try out.appendSlice(gpa, ";1");
    if (style.dim) try out.appendSlice(gpa, ";2");
    if (style.italic) try out.appendSlice(gpa, ";3");
    switch (style.ul_style) {
        .off => {},
        .single => try out.appendSlice(gpa, ";4"),
        .double => try out.appendSlice(gpa, ";21"),
        else => {},
    }
    if (style.blink) try out.appendSlice(gpa, ";5");
    if (style.reverse) try out.appendSlice(gpa, ";7");
    if (style.invisible) try out.appendSlice(gpa, ";8");
    if (style.strikethrough) try out.appendSlice(gpa, ";9");
    try writeColor(gpa, out, style.fg, false);
    try writeColor(gpa, out, style.bg, true);
    try out.append(gpa, 'm');
}

fn writeColor(gpa: Allocator, out: *std.ArrayList(u8), color: vaxis.Cell.Color, bg: bool) !void {
    switch (color) {
        .default => {},
        .index => |i| {
            const base: u8 = if (i < 8)
                (if (bg) @as(u8, 40) else 30) + i
            else if (i < 16)
                (if (bg) @as(u8, 100) else 90) + i - 8
            else
                0;
            if (i < 16) {
                try out.print(gpa, ";{d}", .{base});
            } else {
                try out.print(gpa, ";{s};5;{d}", .{ if (bg) "48" else "38", i });
            }
        },
        .rgb => |rgb| {
            try out.print(gpa, ";{s};2;{d};{d};{d}", .{ if (bg) "48" else "38", rgb[0], rgb[1], rgb[2] });
        },
    }
}

pub const Dispatch = struct {
    redraw: bool,
    consume_event: bool,
    quit: bool,
    cmds: vxfw.CommandList,
    /// The widget that requested focus while handling the event, if any —
    /// like the real app, ticks should be sent to it afterwards.
    focused: ?vxfw.Widget = null,

    pub fn deinit(self: *Dispatch, gpa: Allocator) void {
        self.cmds.deinit(gpa);
    }
};

/// Delivers an event to the widget and returns the resulting context flags.
pub fn send(gpa: Allocator, widget: vxfw.Widget, event: vxfw.Event) !Dispatch {
    var cmds: vxfw.CommandList = .empty;
    errdefer cmds.deinit(gpa);
    var event_ctx = vxfw.EventContext{ .alloc = gpa, .cmds = cmds };
    try widget.handleEvent(&event_ctx, event);
    var focused: ?vxfw.Widget = null;
    for (event_ctx.cmds.items) |cmd| {
        switch (cmd) {
            .request_focus => |w| focused = w,
            else => {},
        }
    }
    return .{
        .redraw = event_ctx.redraw,
        .consume_event = event_ctx.consume_event,
        .quit = event_ctx.quit,
        .cmds = event_ctx.cmds,
        .focused = focused,
    };
}

pub fn keyPress(codepoint: u21) vxfw.Event {
    return .{ .key_press = .{ .codepoint = codepoint, .mods = .{} } };
}

pub fn mouse(button: vaxis.Mouse.Button, mtype: vaxis.Mouse.Type, row: u16, col: u16) vxfw.Event {
    return .{ .mouse = .{
        .col = col,
        .row = row,
        .button = button,
        .type = mtype,
        .mods = .{},
    } };
}

pub const tick: vxfw.Event = .tick;
