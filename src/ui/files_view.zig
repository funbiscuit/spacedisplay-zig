const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const utils = @import("utils.zig");
const format = @import("../core/format.zig");
const ConfirmDialog = @import("ConfirmDialog.zig").ConfirmDialog;
const ModalHost = @import("ModalHost.zig").ModalHost;

const Allocator = std.mem.Allocator;

/// Directory listing widget, generic over Ctx (runtime.Scanner in prod,
/// TestCtx in tests). Ctx contract: listDir may fail DirMissing (view
/// falls back to the parent); requestDelete/takeError drive deletions.
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
        /// Null until setModalHost wires it; without a host the Delete
        /// key is a no-op (bare views in per-widget tests).
        _confirm_dialog: ?ConfirmDialog = null,
        /// Deletion failure shown as a red bar; expires on the tick after
        /// toast_duration_ms or on any key press.
        _toast: ?Toast = null,

        const toast_duration_ms: i64 = 3000;

        const Toast = struct {
            msg: []u8,
            shown_ms: i64,
        };

        pub fn init(allocator: Allocator, ctx: *Ctx) Self {
            return .{
                ._allocator = allocator,
                ._ctx = ctx,
            };
        }

        /// Wires the confirmation dialog to the host. Call after the view
        /// and its owner reached their final addresses: the dialog keeps a
        /// host pointer that by-value copies would invalidate.
        pub fn setModalHost(self: *Self, host: *ModalHost) void {
            self._confirm_dialog = ConfirmDialog.init(self._allocator, host);
        }

        pub fn deinit(self: *Self) void {
            if (self._confirm_dialog) |*dialog| dialog.deinit();
            self.clearToast();
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

        /// Lists the directory currently open. When it cannot be opened —
        /// deleted outside the app, or by a queued delete while we were
        /// inside it — falls back to the parent and lists that instead.
        /// Returns null when even the scanned root is gone; the caller then
        /// settles for an empty listing.
        fn listOpenedDir(self: *Self) !?std.ArrayList(Ctx.ListDirEntry) {
            while (true) {
                const entries = self._ctx.listDir(self._allocator, self._opened_dir_id) catch |err| switch (err) {
                    error.DirMissing => {
                        const parent = self._ctx.getParentId(self._opened_dir_id) orelse return null;
                        self._opened_dir_id = parent;
                        self._selected_index = 0;
                        self._offset = 0;
                        self._hovered_index = null;
                        continue;
                    },
                    else => return err,
                };
                return entries;
            }
        }

        fn updateEntries(self: *Self, params: UpdateParams) !bool {
            const new_scanned_id = self._ctx.getScannedChildId(self._opened_dir_id);
            const scanned_changed = new_scanned_id != self._scanned_child_id;
            self._scanned_child_id = new_scanned_id;
            const now = self._ctx.nowMs();
            if (self._ctx.hasChanges() or params.force or self._last_update_time + 500 < now) {
                self._last_update_time = now;
                const entries = (try self.listOpenedDir()) orelse std.ArrayList(Ctx.ListDirEntry).empty;
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

        /// One pending delete confirmation: what the dialog was asked
        /// about. `dir` is the listing the entry came from, captured at
        /// key-press time — the opened dir may change (or vanish) while
        /// the dialog is up.
        const DeleteRequest = struct {
            view: *Self,
            dir: Ctx.EntryId,
            name: []u8,
        };

        fn setToast(self: *Self, msg: []const u8) !void {
            const copy = try self._allocator.dupe(u8, msg);
            self.clearToast();
            self._toast = .{ .msg = copy, .shown_ms = self._ctx.nowMs() };
        }

        fn clearToast(self: *Self) void {
            if (self._toast) |toast| self._allocator.free(toast.msg);
            self._toast = null;
        }

        fn deleteSelectedEntry(self: *Self, ctx: *vxfw.EventContext) !void {
            const dialog: *ConfirmDialog = if (self._confirm_dialog) |*d| d else return;
            if (self._selected_index >= self._entries.items.len) return;
            const entry = self._entries.items[self._selected_index];
            // "." and ".." navigate; they are not deletion targets
            if (entry.kind == .parent) return;

            // The listing keeps refreshing while the dialog is open (ticks
            // still fire), so the name — not the index — is the stable
            // handle.
            const name = try self._allocator.dupe(u8, entry.name);
            const req = try self._allocator.create(DeleteRequest);
            req.* = .{ .view = self, .dir = self._opened_dir_id, .name = name };
            errdefer self.freeDeleteRequest(req);

            const question = try self._allocator.print("Delete '{s}'?", .{entry.name});
            defer self._allocator.free(question);

            dialog.show(ctx, "Confirm Deletion", question, req, onDialogResult) catch |err| switch (err) {
                // unreachable while a modal is open: the base is composited
                // away and never sees keys; stay leak-free regardless
                error.AlreadyShowing => self.freeDeleteRequest(req),
                else => return err,
            };
        }

        fn freeDeleteRequest(self: *Self, req: *DeleteRequest) void {
            self._allocator.free(req.name);
            self._allocator.destroy(req);
        }

        fn onDialogResult(userdata: ?*anyopaque, result: ConfirmDialog.Result) anyerror!void {
            const req: *DeleteRequest = @ptrCast(@alignCast(userdata orelse return));
            defer req.view.freeDeleteRequest(req);
            if (result != .confirmed) return;
            try req.view._ctx.requestDelete(req.view._allocator, req.dir, req.name);
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
                    if (self._toast != null) {
                        self.clearToast();
                        ctx.redraw = true;
                    }
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
                    if (key.matches(vaxis.Key.delete, .{})) {
                        try self.deleteSelectedEntry(ctx);
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
                    var buf: [256]u8 = undefined;
                    if (self._ctx.takeError(&buf)) |msg| {
                        try self.setToast(msg);
                        ctx.redraw = true;
                    }
                    if (self._toast) |*toast| {
                        if (self._ctx.nowMs() - toast.shown_ms >= toast_duration_ms) {
                            self.clearToast();
                            ctx.redraw = true;
                        }
                    }
                    ctx.redraw = (try self.updateEntries(.{})) or ctx.redraw;
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
                const entry_text = try ctx.arena.print(
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
                    // an all-zero listing would make the share 0/0 = NaN,
                    // and @intFromFloat(NaN) is arch-dependent UB
                    const bar_width: f64 = if (max_entry_size > 0)
                        @as(f64, @floatFromInt(e.size * max_bar_width)) / max_entry_size
                    else
                        0;
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

            if (self._toast) |toast| {
                // red bar over the last listing row; the app's progress
                // bar sits outside this view and stays visible
                const toast_style: vaxis.Style = .{
                    .fg = .{ .index = 7 },
                    .bg = .{ .index = 1 },
                    .bold = true,
                };
                const bar = try vxfw.Surface.init(
                    ctx.arena,
                    self.widget(),
                    .{ .width = max_size.width, .height = 1 },
                );
                @memset(bar.buffer, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = toast_style });
                try children.append(ctx.arena, .{
                    .origin = .{ .row = max_size.height - 1, .col = 0 },
                    .surface = bar,
                });

                const text: vxfw.Text = .{
                    .text = toast.msg,
                    .style = toast_style,
                    .softwrap = false,
                };
                var text_ctx = ctx;
                text_ctx.max.width = max_size.width -| 1;
                try children.append(ctx.arena, .{
                    .origin = .{ .row = max_size.height - 1, .col = 1 },
                    .surface = try text.draw(text_ctx),
                });
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
