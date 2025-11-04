const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Scanner = @import("../Scanner.zig");
const Tree = @import("../Tree.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const FilesView = @This();

_allocator: Allocator,
_scanner: *Scanner,
_offset: u32 = 0,
_opened_dir_id: Tree.EntryId = .root,
_scanned_child_id: Tree.EntryId = .none,
_selected_index: usize = 1,
_last_mouse_row: ?u32 = null,
_last_height: ?u16 = null,
_entries: std.ArrayList(Scanner.ListDirEntry) = .empty,

pub fn init(allocator: Allocator, scanner: *Scanner) FilesView {
    return .{
        ._allocator = allocator,
        ._scanner = scanner,
    };
}

pub fn deinit(self: *FilesView) void {
    Scanner.deinitListDir(self._allocator, &self._entries);
}

pub fn widget(self: *FilesView) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = FilesView.typeErasedEventHandler,
        .drawFn = FilesView.typeErasedDrawFn,
    };
}

fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *FilesView = @ptrCast(@alignCast(ptr));
    return self.handleEvent(ctx, event);
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *FilesView = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

const UpdateParams = struct {
    force: bool = false,
    select_id: Tree.EntryId = .none,
};

fn updateEntries(self: *FilesView, params: UpdateParams) !bool {
    const new_scanned_id = self._scanner.getScannedChildId(self._opened_dir_id);
    const scanned_changed = !new_scanned_id.eql(self._scanned_child_id);
    self._scanned_child_id = new_scanned_id;
    if (self._scanner.hasChanges() or params.force) {
        const entries = try self._scanner.listDir(self._allocator, self._opened_dir_id);
        Scanner.deinitListDir(self._allocator, &self._entries);
        self._entries = entries;
        if (params.select_id.isSome()) {
            for (self._entries.items, 0..) |e, i| {
                if (e.id.eql(params.select_id)) {
                    self._selected_index = i;
                }
            }
        }
        return true;
    }

    return scanned_changed;
}

fn openEntry(self: *FilesView, index: usize) !bool {
    if (index < self._entries.items.len) {
        const entry = self._entries.items[index];
        if (entry.id.isSome()) {
            self._opened_dir_id = entry.id;
            self._offset = 0;
            self._selected_index = self._last_mouse_row orelse 1;
            _ = try self.updateEntries(.{ .force = true });
            return true;
        }
    }
    return false;
}

fn updateMouseShape(self: *FilesView, ctx: *vxfw.EventContext) !void {
    if (self._last_mouse_row) |row| {
        const index = self._offset + row;
        if (index < self._entries.items.len and self._entries.items[index].id.isSome()) {
            return ctx.setMouseShape(.pointer);
        }
    }
    return ctx.setMouseShape(.default);
}

pub fn handleEvent(self: *FilesView, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    switch (event) {
        .init => {
            try ctx.tick(0, self.widget());
        },
        .key_press => |key| {
            try ctx.setMouseShape(.default);
            if (key.matches(vaxis.Key.escape, .{}) or
                key.matches(vaxis.Key.backspace, .{}) or
                key.matches(vaxis.Key.left, .{}))
            {
                const parent = self._scanner.getParentId(self._opened_dir_id);
                if (parent.isSome()) {
                    const select_id = self._opened_dir_id;
                    self._opened_dir_id = parent;
                    self._selected_index = 0;
                    _ = try self.updateEntries(.{ .force = true, .select_id = select_id });
                }
                return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.up, .{})) {
                if (self._selected_index > 0) {
                    self._selected_index -= 1;
                }
                return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.down, .{})) {
                self._selected_index += 1;
                return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.enter, .{}) or
                key.matches(vaxis.Key.right, .{}))
            {
                if (try self.openEntry(self._selected_index)) {
                    ctx.redraw = true;
                }
                return ctx.consumeEvent();
            }
            if (key.matches(vaxis.Key.home, .{})) {
                self._selected_index = 1;
                return ctx.consumeAndRedraw();
            }
            if (key.matches(vaxis.Key.end, .{})) {
                self._selected_index = self._entries.items.len;
                return ctx.consumeAndRedraw();
            }
        },
        .mouse => |mouse| {
            self._last_mouse_row = mouse.row;
            if (mouse.type == .motion) {
                self._selected_index = self._offset + mouse.row;
                ctx.redraw = true;
                try self.updateMouseShape(ctx);
            }
            if (mouse.button == .wheel_up) {
                if (self._offset > 0) {
                    self._offset -= 1;
                    self._selected_index = self._offset + mouse.row;
                }
                ctx.consumeAndRedraw();
            }
            if (mouse.button == .wheel_down) {
                self._offset += 1;
                if (self._last_height) |height| {
                    if (height > self._entries.items.len) {
                        self._offset = 0;
                    } else {
                        self._offset = @min(self._offset, self._entries.items.len - height);
                    }
                }
                self._selected_index = self._offset + mouse.row;
                ctx.consumeAndRedraw();
            }
            if (mouse.button == .left and mouse.type == .release) {
                if (try self.openEntry(self._offset + mouse.row)) {
                    try self.updateMouseShape(ctx);
                    ctx.consumeAndRedraw();
                }
            }
        },
        .tick => {
            ctx.redraw = try self.updateEntries(.{});
            try ctx.tick(20, self.widget());
        },
        else => {},
    }
}

pub fn draw(self: *FilesView, ctx: vxfw.DrawContext) !vxfw.Surface {
    const max_size = ctx.max.size();
    self._last_height = max_size.height;

    //TODO better scaling for smaller sizes
    if (self._entries.items.len == 0 or max_size.width < 50) {
        return .{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = &.{},
        };
    }

    if (self._entries.items.len < max_size.height) {
        self._offset = 0;
    } else {
        self._offset = @min(self._offset, self._entries.items.len - max_size.height);
    }
    if (self._selected_index >= self._entries.items.len) {
        self._selected_index = self._entries.items.len - 1;
    }
    if (self._selected_index < self._offset) {
        self._offset = @intCast(self._selected_index);
    }
    if (self._selected_index >= self._offset + max_size.height) {
        self._offset = @intCast(self._selected_index - max_size.height + 1);
    }

    const num = @min(max_size.height, self._entries.items.len - self._offset);
    var children = std.ArrayList(vxfw.SubSurface).empty;
    try children.ensureTotalCapacity(ctx.arena, num);

    var max_entry_size: f64 = 0;
    for (self._entries.items) |e| {
        max_entry_size += @floatFromInt(e.size);
    }

    const max_name_width = 30;

    const max_bar_width = max_size.width - max_name_width - 6 - 8 - 2;

    for (self._entries.items[self._offset .. self._offset + num], 0..) |e, i| {
        const is_selected = i + self._offset == self._selected_index;
        const prefix = if (is_selected) ">" else " ";

        const name_text = try utils.nameToUtf8(ctx.arena, e.name);
        const entry_text = try std.fmt.allocPrint(
            ctx.arena,
            " {s} {s}",
            .{ prefix, name_text },
        );
        const style: vaxis.Style = if (e.kind == .directory or e.kind == .parent)
            .{ .fg = .{ .index = 3 }, .bold = is_selected }
        else
            .{ .fg = .{ .index = 4 }, .bold = is_selected };

        const entry_widget: vxfw.Text = .{
            .text = entry_text,
            .style = style,
            .softwrap = false,
        };

        var entry_ctx = ctx;
        entry_ctx.max.width = max_name_width + 3;
        try children.append(ctx.arena, .{
            .origin = .{ .row = @intCast(i), .col = 0 },
            .surface = try entry_widget.draw(entry_ctx),
        });

        if (e.kind != .parent) {
            const size_text = try utils.formatSize(ctx.arena, e.size, 4);
            const size_widget: vxfw.Text = .{
                .text = size_text,
                .style = style,
            };
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(i), .col = max_name_width + 4 },
                .surface = try size_widget.draw(ctx),
            });

            //TODO extract to separate widget
            const bar_width = @as(f64, @floatFromInt(e.size * max_bar_width)) / max_entry_size;
            const bar_surface = try vxfw.Surface.init(
                ctx.arena,
                self.widget(),
                .{ .width = max_bar_width, .height = 1 },
            );
            const base_style: vaxis.Style = .{
                .fg = .default,
                .bg = .default,
                .reverse = false,
            };
            const base: vaxis.Cell = .{ .style = base_style };
            @memset(bar_surface.buffer, base);

            const bar_chunks = [_][]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" };
            const full_chunks: usize = @intFromFloat(bar_width);
            for (0..@min(full_chunks, bar_surface.buffer.len)) |bar_i| {
                bar_surface.buffer[bar_i] = .{
                    .style = .{ .bg = .{ .index = 3 } },
                };
            }
            if (full_chunks < bar_surface.buffer.len) {
                const leftover: usize = @intFromFloat(@round((bar_width - @floor(bar_width)) * @as(f64, @floatFromInt(bar_chunks.len))));
                if (leftover == bar_chunks.len) {
                    bar_surface.buffer[full_chunks] = .{
                        .style = .{ .bg = .{ .index = 3 } },
                    };
                } else if (leftover > 0) {
                    bar_surface.buffer[full_chunks] = .{
                        .char = .{ .grapheme = bar_chunks[leftover] },
                        .style = .{ .fg = .{ .index = 3 } },
                    };
                }
            }
            try children.append(ctx.arena, .{
                .origin = .{ .row = @intCast(i), .col = max_name_width + 6 + 8 + 1 },
                .surface = bar_surface,
            });

            if (self._scanned_child_id.isSome() and e.id.eql(self._scanned_child_id)) {
                const frames: []const []const u8 = &.{ "⠋", "⠙", "⠹", "⢸", "⣰", "⣠", "⣄", "⣆", "⡇", "⠏" };
                const frame = (@as(usize, @intCast(@max(0, std.time.milliTimestamp()))) / 100) % frames.len;
                const spinner_widget: vxfw.Text = .{
                    .text = frames[frame],
                    .style = style,
                };
                try children.append(ctx.arena, .{
                    .origin = .{ .row = @intCast(i), .col = max_name_width + 6 + 8 + 1 - 2 },
                    .surface = try spinner_widget.draw(ctx),
                });
            }
        }
    }

    return .{
        .size = max_size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children.items,
    };
}
