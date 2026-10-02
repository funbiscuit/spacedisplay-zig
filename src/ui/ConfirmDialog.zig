//! Modal confirmation dialog: a question with [Y]es / [N]o / [Esc] answers.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;
const ModalHost = @import("ModalHost.zig").ModalHost;

pub const ConfirmDialog = @This();

pub const Result = enum { confirmed, cancelled };
pub const Callback = *const fn (userdata: ?*anyopaque, result: Result) anyerror!void;

const width_chars = 40;
const height_rows = 4;
/// The app-wide accent color (same hue as directories and the progress bar).
const accent: u8 = 3;

_title: []const u8 = "",
_question: []const u8 = "",
_userdata: ?*anyopaque = null,
_on_result: ?Callback = null,
_open: bool = false,
_host: *ModalHost,
_allocator: Allocator,

pub fn init(allocator: Allocator, host: *ModalHost) ConfirmDialog {
    return .{ ._host = host, ._allocator = allocator };
}

pub fn deinit(self: *ConfirmDialog) void {
    // Teardown while shown: report .cancelled so caller-owned userdata is
    // freed by the same code path that allocated it. The stale entry stays
    // on the host stack until the host itself is torn down; it is never
    // drawn or focused again.
    if (self._open) {
        self._open = false;
        if (self._on_result) |callback| {
            const userdata = self._userdata;
            self._userdata = null;
            self._on_result = null;
            callback(userdata, .cancelled) catch {};
        }
    }
    self.clearStrings();
}

/// Shows the dialog over the base view. `userdata` and its freeing remain
/// the caller's responsibility; the callback receives it with the result.
pub fn show(
    self: *ConfirmDialog,
    ctx: *vxfw.EventContext,
    title: []const u8,
    question: []const u8,
    userdata: ?*anyopaque,
    on_result: ?Callback,
) (Allocator.Error || error{AlreadyShowing})!void {
    if (self._open) return error.AlreadyShowing;

    const title_dup = try self._allocator.dupe(u8, title);
    errdefer self._allocator.free(title_dup);
    const question_dup = try self._allocator.dupe(u8, question);
    errdefer self._allocator.free(question_dup);

    self._title = title_dup;
    self._question = question_dup;
    self._userdata = userdata;
    self._on_result = on_result;
    self._open = true;
    return self._host.push(ctx, .{ .widget = self.widget() });
}

pub fn widget(self: *ConfirmDialog) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *ConfirmDialog = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *ConfirmDialog = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

fn handleEvent(self: *ConfirmDialog, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    switch (event) {
        .key_press => |key| {
            if (key.matches('y', .{}) or key.matches('Y', .{})) {
                return self.report(ctx, .confirmed);
            }
            if (key.matches('n', .{}) or key.matches('N', .{}) or
                key.matches(vaxis.Key.escape, .{}))
            {
                return self.report(ctx, .cancelled);
            }
        },
        // Modal contract: consume every mouse event; the host's shield
        // handles the clicks outside this dialog.
        .mouse => return ctx.consumeEvent(),
        else => {},
    }
}

fn report(self: *ConfirmDialog, ctx: *vxfw.EventContext, result: Result) !void {
    // The dialog handled the key that produced this result; nothing below
    // may see it. Pop before the callback so the callback can push another
    // modal.
    ctx.consumeEvent();
    try self._host.pop(ctx);
    const callback = self._on_result;
    const userdata = self._userdata;
    self._open = false;
    self._on_result = null;
    self._userdata = null;
    self.clearStrings();
    if (callback) |cb| return cb(userdata, result);
}

fn clearStrings(self: *ConfirmDialog) void {
    if (self._title.len > 0) self._allocator.free(self._title);
    if (self._question.len > 0) self._allocator.free(self._question);
    self._title = "";
    self._question = "";
}

pub fn draw(self: *ConfirmDialog, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const width = @min(width_chars, ctx.max.width orelse width_chars);
    const height = @min(height_rows, ctx.max.height orelse height_rows);
    const surface = try vxfw.Surface.init(ctx.arena, self.widget(), .{
        .width = width,
        .height = height,
    });

    // black background (the dim backdrop's color), accent
    // border and text, title embedded in the top border. The
    // buffer is filled and text is written into it directly because
    // rendering never skips default cells.
    const card: vaxis.Style = .{ .fg = .{ .index = accent }, .bg = .{ .index = 0 } };
    const title_style: vaxis.Style = .{ .fg = .{ .index = accent }, .bg = .{ .index = 0 }, .bold = true };
    @memset(surface.buffer, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = card });

    const right = width - 1;
    const bottom = height - 1;
    surface.writeCell(0, 0, .{ .char = .{ .grapheme = "╭", .width = 1 }, .style = card });
    surface.writeCell(right, 0, .{ .char = .{ .grapheme = "╮", .width = 1 }, .style = card });
    surface.writeCell(right, bottom, .{ .char = .{ .grapheme = "╯", .width = 1 }, .style = card });
    surface.writeCell(0, bottom, .{ .char = .{ .grapheme = "╰", .width = 1 }, .style = card });
    var col: u16 = 1;
    while (col < right) : (col += 1) {
        surface.writeCell(col, 0, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = card });
        surface.writeCell(col, bottom, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = card });
    }
    var row: u16 = 1;
    while (row < bottom) : (row += 1) {
        surface.writeCell(0, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = card });
        surface.writeCell(right, row, .{ .char = .{ .grapheme = "│", .width = 1 }, .style = card });
    }

    // spaces keep the title from touching the border line
    const title = std.fmt.allocPrint(ctx.arena, " {s} ", .{self._title}) catch return error.OutOfMemory;
    writeCenteredOver(surface, ctx, title, 0, title_style);
    writeCentered(surface, ctx, 1, self._question, card);
    writeCentered(surface, ctx, 2, "[Y]es  [N]o  [Esc] cancel", card);
    return surface;
}

/// Like writeCentered, but overwrites border cells: used for the title
/// embedded in the top border line.
fn writeCenteredOver(surface: vxfw.Surface, ctx: vxfw.DrawContext, text: []const u8, row: u16, style: vaxis.Style) void {
    const text_width: u16 = @intCast(ctx.stringWidth(text));
    if (text_width > surface.size.width) return;
    const col = (surface.size.width - text_width) / 2;
    var i: u16 = 0;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const g = grapheme.bytes(text);
        const g_width: u16 = @intCast(ctx.stringWidth(g));
        surface.writeCell(col + i, row, .{ .char = .{ .grapheme = g, .width = @intCast(g_width) }, .style = style });
        i += g_width;
    }
}

/// Writes one line into the surface, centered and clipped at the edges.
fn writeCentered(surface: vxfw.Surface, ctx: vxfw.DrawContext, row: u16, text: []const u8, style: vaxis.Style) void {
    const text_width: u16 = @intCast(ctx.stringWidth(text));
    var col: u16 = if (text_width >= surface.size.width)
        0
    else
        (surface.size.width - text_width) / 2;
    var iter = ctx.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const g = grapheme.bytes(text);
        const g_width: u16 = @intCast(ctx.stringWidth(g));
        if (col + g_width > surface.size.width) break;
        surface.writeCell(col, row, .{ .char = .{ .grapheme = g, .width = @intCast(g_width) }, .style = style });
        col += g_width;
    }
}
