//! Full-screen modal layer: stacks modal widgets above a base view.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;

/// One level of the modal stack.
pub const Entry = struct {
    widget: vxfw.Widget,
    /// A left press outside the modal pops it. Only applies to the top of
    /// the stack; lower levels receive no input at all.
    dismiss_on_click_outside: bool = true,
};

/// Wraps a base view and draws modal entries on top of it. The base and all
/// but the top entry are composited into one buffer and dimmed; the top entry
/// stays a real child surface, so vxfw routes keyboard events to it via focus
/// and mouse events via hit-testing. Everything below the top is pixels only:
/// it must not receive input, and one full-screen shield surface is enough to
/// catch all clicks the top modal does not.
pub const ModalHost = @This();

_allocator: Allocator,
_stack: std.ArrayList(Entry) = .empty,
_base: ?vxfw.Widget = null,
/// Focused again when the stack empties.
_base_focus: ?vxfw.Widget = null,

pub fn init(allocator: Allocator) ModalHost {
    return .{ ._allocator = allocator };
}

pub fn deinit(self: *ModalHost) void {
    self._stack.deinit(self._allocator);
}

/// Sets the wrapped view and the focus target restored when the stack
/// empties. The owner must call this after it has reached its final address:
/// by-value init copies invalidate pointers taken during init.
pub fn setBase(self: *ModalHost, base: vxfw.Widget, restore_focus: vxfw.Widget) void {
    self._base = base;
    self._base_focus = restore_focus;
}

pub fn widget(self: *ModalHost) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedEventHandler,
        .drawFn = typeErasedDrawFn,
    };
}

/// The shield facet: an invisible full-screen surface that receives every
/// mouse event the top modal does not. Drawn as a child of the modal layer.
pub fn shieldWidget(self: *ModalHost) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = typeErasedShieldHandler,
        .drawFn = typeErasedShieldDraw,
    };
}

pub fn push(self: *ModalHost, ctx: *vxfw.EventContext, entry: Entry) Allocator.Error!void {
    try self._stack.append(self._allocator, entry);
    ctx.redraw = true;
    return ctx.requestFocus(entry.widget);
}

pub fn pop(self: *ModalHost, ctx: *vxfw.EventContext) Allocator.Error!void {
    if (!self.active()) return;
    _ = self._stack.pop();
    ctx.redraw = true;
    const focus = if (self.active()) self.top().?.widget else self._base_focus.?;
    return ctx.requestFocus(focus);
}

pub fn top(self: *const ModalHost) ?Entry {
    if (!self.active()) return null;
    return self._stack.items[self._stack.items.len - 1];
}

pub fn active(self: *const ModalHost) bool {
    return self._stack.items.len > 0;
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *ModalHost = @ptrCast(@alignCast(ptr));
    switch (event) {
        // The app delivers .init to the root only; pass it on to the base.
        .init => {
            if (self._base) |base| return base.handleEvent(ctx, event);
        },
        else => {},
    }
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *ModalHost = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

fn draw(self: *ModalHost, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const base = self._base orelse @panic("ModalHost.setBase was never called");
    const base_surface = try base.draw(ctx);
    if (!self.active()) return base_surface;

    const max = ctx.max.size();
    var layer = try vxfw.Surface.init(ctx.arena, self.widget(), max);

    // Everything below the top modal ends up in the buffer, dimmed once per
    // level above it; the top modal is drawn bright as a child surface.
    blend(&layer, base_surface, 0, 0);
    dim(layer.buffer);
    for (self._stack.items[0 .. self._stack.items.len - 1]) |entry| {
        const surface = try entry.widget.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = max.height }));
        const origin = centeredOrigin(surface.size, max);
        blend(&layer, surface, origin.row, origin.col);
        dim(layer.buffer);
    }

    const top_entry = self.top().?;
    const top_surface = try top_entry.widget.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = max.height }));

    const shield_surface = vxfw.Surface{
        .size = max,
        .widget = self.shieldWidget(),
        .buffer = &.{},
        .children = &.{},
    };
    const children = try ctx.arena.alloc(vxfw.SubSurface, 2);
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = shield_surface };
    children[1] = .{
        .origin = centeredOrigin(top_surface.size, max),
        .surface = top_surface,
        .z_index = 1,
    };
    layer.children = children;
    return layer;
}

fn typeErasedShieldHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *ModalHost = @ptrCast(@alignCast(ptr));
    switch (event) {
        .mouse => |mouse| {
            // Only a press aimed at the shield dismisses; events bubbling up
            // from the top modal arrive in the bubbling phase and are merely
            // consumed (the modal contract says a modal never ignores a
            // press, so this only fires for clicks outside it).
            if (ctx.phase == .at_target and mouse.type == .press and mouse.button == .left) {
                if (self.top()) |entry| {
                    if (entry.dismiss_on_click_outside) {
                        ctx.consumeEvent();
                        return self.pop(ctx);
                    }
                }
            }
            return ctx.consumeEvent();
        },
        else => {},
    }
}

fn typeErasedShieldDraw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *ModalHost = @ptrCast(@alignCast(ptr));
    // The shield is visual nothing: it exists to be hit-tested.
    return .{
        .size = ctx.max.size(),
        .widget = self.shieldWidget(),
        .buffer = &.{},
        .children = &.{},
    };
}

/// Copies src and its child surfaces into dst at the given offset. Cells left
/// in their default state count as transparent, so a surface only covers what
/// it actually draws.
fn blend(dst: *vxfw.Surface, src: vxfw.Surface, row_off: i32, col_off: i32) void {
    for (src.buffer, 0..) |cell, i| {
        if (cell.default) continue;
        const row = row_off + @as(i32, @intCast(i / src.size.width));
        const col = col_off + @as(i32, @intCast(i % src.size.width));
        if (row < 0 or col < 0 or row >= dst.size.height or col >= dst.size.width) continue;
        dst.writeCell(@intCast(col), @intCast(row), cell);
    }
    for (src.children) |child| {
        blend(dst, child.surface, row_off + child.origin.row, col_off + child.origin.col);
    }
}

/// Dims cells in place: every fg and bg color is scaled toward black by a
/// fixed factor and snapped back to the nearest palette entry, so a dimmed
/// layer recedes uniformly — light panels become gray panels, black text
/// stays readable on them, colored glyphs darken but keep their hue.
/// `.default` counts as white for fg and black for bg (the app assumes a
/// dark terminal). Stays in palette-index space, so no truecolor is needed;
/// the faint SGR attribute is deliberately not used (it only affects glyphs,
/// and some terminals ignore it).
fn dim(buffer: []vaxis.Cell) void {
    for (buffer) |*cell| {
        cell.default = false;
        cell.style.fg = dimColor(cell.style.fg, dimmed_default_fg);
        cell.style.bg = dimColor(cell.style.bg, .{ .index = 0 });
    }
}

const dimmed_default_fg: vaxis.Cell.Color = blk: {
    @setEvalBranchQuota(10_000);
    break :blk .{ .index = nearestIndex(scaleRgb(.{ 255, 255, 255 })) };
};

fn dimColor(color: vaxis.Cell.Color, dimmed_default: vaxis.Cell.Color) vaxis.Cell.Color {
    return switch (color) {
        .default => dimmed_default,
        .index => |i| .{ .index = dim_lut[i] },
        .rgb => |rgb| .{ .rgb = scaleRgb(rgb) },
    };
}

/// Fraction of each RGB channel that survives dimming, out of 10.
const dim_keep: u32 = 4;

fn scaleRgb(rgb: [3]u8) [3]u8 {
    return .{
        @intCast(@as(u32, rgb[0]) * dim_keep / 10),
        @intCast(@as(u32, rgb[1]) * dim_keep / 10),
        @intCast(@as(u32, rgb[2]) * dim_keep / 10),
    };
}

/// The standard xterm base-16 palette; indices 16-255 are computed from the
/// 6x6x6 cube and grayscale ramps, so the whole table needs no data files.
const base16 = [16][3]u8{
    .{ 0, 0, 0 },       .{ 205, 0, 0 },   .{ 0, 205, 0 },   .{ 205, 205, 0 },
    .{ 0, 0, 238 },     .{ 205, 0, 205 }, .{ 0, 205, 205 }, .{ 229, 229, 229 },
    .{ 127, 127, 127 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
    .{ 92, 92, 255 },   .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
};

fn paletteRgb(i: u8) [3]u8 {
    if (i < 16) return base16[i];
    if (i < 232) {
        const n = i - 16;
        const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
        return .{ levels[n / 36], levels[(n / 6) % 6], levels[n % 6] };
    }
    return .{ 8 + (i - 232) * 10, 8 + (i - 232) * 10, 8 + (i - 232) * 10 };
}

fn nearestIndex(rgb: [3]u8) u8 {
    var best: u8 = 0;
    var best_dist: u32 = std.math.maxInt(u32);
    for (0..256) |i| {
        const cand = paletteRgb(@intCast(i));
        const dr: i32 = @as(i32, cand[0]) - rgb[0];
        const dg: i32 = @as(i32, cand[1]) - rgb[1];
        const db: i32 = @as(i32, cand[2]) - rgb[2];
        const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (dist < best_dist) {
            best_dist = dist;
            best = @intCast(i);
        }
    }
    return best;
}

/// Maps every palette index to its dimmed index. Computed at comptime, so
/// runtime dimming is a lookup per cell.
const dim_lut: [256]u8 = blk: {
    @setEvalBranchQuota(500_000);
    var lut: [256]u8 = undefined;
    for (0..256) |i| {
        lut[i] = nearestIndex(scaleRgb(paletteRgb(@intCast(i))));
    }
    break :blk lut;
};

test "dim lookup keeps black, lands whites in the gray ramp" {
    try std.testing.expectEqual(@as(u8, 0), dim_lut[0]);
    try std.testing.expect(dim_lut[7] >= 232);
    try std.testing.expect(dim_lut[15] >= 232);
}

fn centeredOrigin(size: vxfw.Size, max: vxfw.Size) vxfw.RelativePoint {
    const height = @min(size.height, max.height);
    const width = @min(size.width, max.width);
    return .{
        .row = @intCast((max.height - height) / 2),
        .col = @intCast((max.width - width) / 2),
    };
}
