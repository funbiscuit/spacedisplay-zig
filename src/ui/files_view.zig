const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const utils = @import("utils.zig");
const format = @import("../core/format.zig");

const Allocator = std.mem.Allocator;

/// Directory listing widget. Generic over Ctx (runtime.Scanner in prod,
/// scripted context in tests), which provides EntryId/ListDirEntry types
/// and the data methods called below.
pub fn FilesView(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        _allocator: Allocator,
        _ctx: *Ctx,
        _offset: u32 = 0,
        _opened_dir_id: Ctx.EntryId = .root,
        _scanned_child_id: ?Ctx.EntryId = null,
        _selected_index: usize = 1,
        /// Set when the keyboard moved the selection; the next draw scrolls
        /// the view to it. Wheel scrolling deliberately does not set this,
        /// so it can park the selection outside the view.
        _snap_selection: bool = false,
        /// Row the mouse is over (absolute index into _entries), if any.
        /// Deliberately independent of _selected_index: mouse motion moves
        /// only the hover, never the selection.
        _hovered_index: ?usize = null,
        _last_mouse_row: ?u32 = null,
        _last_height: ?u16 = null,
        _last_update_time: i64 = 0,
        _entries: std.ArrayList(Ctx.ListDirEntry) = .empty,

        pub fn init(allocator: Allocator, ctx: *Ctx) Self {
            return .{
                ._allocator = allocator,
                ._ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            Ctx.deinitListDir(self._allocator, &self._entries);
        }

        pub fn widget(self: *Self) vxfw.Widget {
            return .{
                .userdata = self,
                .eventHandler = typeErasedEventHandler,
                .drawFn = typeErasedDrawFn,
            };
        }

        fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.handleEvent(ctx, event);
        }

        fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.draw(ctx);
        }

        const UpdateParams = struct {
            force: bool = false,
            select_id: ?Ctx.EntryId = null,
        };

        fn updateEntries(self: *Self, params: UpdateParams) !bool {
            const new_scanned_id = self._ctx.getScannedChildId(self._opened_dir_id);
            const scanned_changed = new_scanned_id != self._scanned_child_id;
            self._scanned_child_id = new_scanned_id;
            const now = self._ctx.nowMs();
            if (self._ctx.hasChanges() or params.force or self._last_update_time + 500 < now) {
                self._last_update_time = now;
                const entries = try self._ctx.listDir(self._allocator, self._opened_dir_id);
                Ctx.deinitListDir(self._allocator, &self._entries);
                self._entries = entries;
                if (params.select_id) |select_id| {
                    for (self._entries.items, 0..) |e, i| {
                        if (e.id != null and e.id.?.eql(select_id)) {
                            self._selected_index = i;
                        }
                    }
                }
                return true;
            }

            return scanned_changed;
        }

        fn openEntry(self: *Self, index: usize) !bool {
            if (index < self._entries.items.len) {
                const entry = self._entries.items[index];
                if (entry.id) |id| {
                    self._opened_dir_id = id;
                    self._offset = 0;
                    self._selected_index = 1;
                    self._hovered_index = null;
                    _ = try self.updateEntries(.{ .force = true });
                    return true;
                }
            }
            return false;
        }

        /// Hover target for a mouse event on `row`: the absolute entry index
        /// under the cursor, or null past the end of the listing.
        fn hoverIndexAt(self: *Self, row: u32) ?usize {
            const index: usize = self._offset + row;
            return if (index < self._entries.items.len) index else null;
        }

        fn updateMouseShape(self: *Self, ctx: *vxfw.EventContext) !void {
            if (self._last_mouse_row) |row| {
                const index = self._offset + row;
                if (index < self._entries.items.len and self._entries.items[index].id != null) {
                    return ctx.setMouseShape(.pointer);
                }
            }
            return ctx.setMouseShape(.default);
        }

        pub fn handleEvent(self: *Self, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
            switch (event) {
                .init => {
                    try ctx.tick(0, self.widget());
                },
                .key_press => |key| {
                    try ctx.setMouseShape(.default);
                    // Navigation keys drop the hover highlight and scroll
                    // the selection back into view on the next draw; the
                    // next mouse motion brings the highlight back.
                    self._hovered_index = null;
                    self._snap_selection = true;
                    if (key.matches(vaxis.Key.escape, .{}) or
                        key.matches(vaxis.Key.backspace, .{}) or
                        key.matches(vaxis.Key.left, .{}))
                    {
                        if (self._ctx.getParentId(self._opened_dir_id)) |parent| {
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
                    // vaxis reports positions as i16; rows can only be
                    // negative for events outside the widget, which we
                    // never act on below.
                    const row: u32 = @intCast(@max(0, mouse.row));
                    self._last_mouse_row = row;
                    if (mouse.type == .motion) {
                        self._hovered_index = self.hoverIndexAt(row);
                        ctx.redraw = true;
                        try self.updateMouseShape(ctx);
                    }
                    if (mouse.button == .wheel_up) {
                        if (self._offset > 0) {
                            self._offset -= 1;
                            self._hovered_index = self.hoverIndexAt(row);
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
                        self._hovered_index = self.hoverIndexAt(row);
                        ctx.consumeAndRedraw();
                    }
                    if (mouse.button == .left and mouse.type == .release) {
                        // The click first retargets the hover to the row
                        // under the cursor; the hovered entry then becomes
                        // the selection and opens.
                        self._hovered_index = self.hoverIndexAt(row);
                        if (self._hovered_index) |index| {
                            self._selected_index = index;
                            if (try self.openEntry(index)) {
                                try self.updateMouseShape(ctx);
                            }
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

        pub fn draw(self: *Self, ctx: vxfw.DrawContext) !vxfw.Surface {
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
            if (self._hovered_index) |h| {
                if (h >= self._entries.items.len) self._hovered_index = null;
            }
            if (self._snap_selection) {
                self._snap_selection = false;
                const height: u32 = max_size.height;
                const selected: u32 = @intCast(self._selected_index);
                if (selected < self._offset) {
                    self._offset = selected;
                } else if (selected >= self._offset + height) {
                    self._offset = selected - height + 1;
                }
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
                const row_index = i + self._offset;
                const is_selected = row_index == self._selected_index;
                const is_highlighted = row_index == (self._hovered_index orelse self._selected_index);
                const prefix = if (is_selected) ">" else " ";

                const name_text = try utils.nameToUtf8(ctx.arena, e.name);
                const entry_text = try std.fmt.allocPrint(
                    ctx.arena,
                    " {s} {s}",
                    .{ prefix, name_text },
                );
                const style: vaxis.Style = if (e.kind == .directory or e.kind == .parent)
                    .{ .fg = .{ .index = 3 }, .bold = is_highlighted }
                else
                    .{ .fg = .{ .index = 4 }, .bold = is_highlighted };

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
                    const size_text = try format.formatSize(ctx.arena, e.size, 4);
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

                    if (self._scanned_child_id == e.id and e.id != null) {
                        const frames: []const []const u8 = &.{ "⠋", "⠙", "⠹", "⢸", "⣰", "⣠", "⣄", "⣆", "⡇", "⠏" };
                        const frame = (@as(usize, @intCast(@max(0, self._ctx.nowMs()))) / 100) % frames.len;
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
    };
}
