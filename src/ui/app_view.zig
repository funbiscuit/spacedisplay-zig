const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const FilesView = @import("files_view.zig").FilesView;
const ProgressBar = @import("ProgressBar.zig");

const Allocator = std.mem.Allocator;

/// Top-level widget: bordered file list plus the progress bar. Ctx provides
/// everything FilesView needs plus getEntryPath and getStats.
pub fn AppView(comptime Ctx: type) type {
    return struct {
        const AppWindow = @This();

        _allocator: Allocator,
        _ctx: *Ctx,
        _files_view: FilesView(Ctx),

        pub fn init(allocator: Allocator, ctx: *Ctx) !AppWindow {
            return .{
                ._allocator = allocator,
                ._ctx = ctx,
                ._files_view = FilesView(Ctx).init(allocator, ctx),
            };
        }

        pub fn deinit(self: *AppWindow) void {
            self._files_view.deinit();
        }

        pub fn widget(self: *AppWindow) vxfw.Widget {
            return .{
                .userdata = self,
                .eventHandler = typeErasedEventHandler,
                .drawFn = typeErasedDrawFn,
            };
        }

        fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
            const self: *AppWindow = @ptrCast(@alignCast(ptr));
            return self.handleEvent(ctx, event);
        }

        fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const self: *AppWindow = @ptrCast(@alignCast(ptr));
            return self.draw(ctx);
        }

        fn handleEvent(self: *AppWindow, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
            switch (event) {
                .init => {
                    try self._files_view.handleEvent(ctx, event);
                    return ctx.requestFocus(self._files_view.widget());
                },
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        ctx.quit = true;
                        return;
                    }
                },
                .focus_in => {
                    return ctx.requestFocus(self._files_view.widget());
                },
                else => {},
            }
        }

        fn draw(self: *AppWindow, ctx: vxfw.DrawContext) !vxfw.Surface {
            const max_size = ctx.max.size();

            var children = std.ArrayList(vxfw.SubSurface).empty;

            //TODO if path is too long, it will clip. Replace path parts with ellipsis in this case
            const opened_path = try self._ctx.getEntryPath(ctx.arena, self._files_view._opened_dir_id);

            const border: vxfw.Border = .{
                .child = self._files_view.widget(),
                .labels = &[_]vxfw.Border.BorderLabel{
                    .{
                        .text = try std.fmt.allocPrint(ctx.arena, " {s} ", .{opened_path}),
                        .alignment = .top_left,
                    },
                },
            };

            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try border.draw(ctx.withConstraints(
                    ctx.min,
                    .{
                        .width = max_size.width,
                        .height = max_size.height - 1,
                    },
                )),
            });

            const stats: ProgressBar = .{
                .stats = try self._ctx.getStats(ctx.arena, self._files_view._opened_dir_id),
            };

            try children.append(ctx.arena, .{
                .origin = .{ .row = max_size.height - 1, .col = 0 },
                .surface = try stats.draw(ctx.withConstraints(
                    ctx.min,
                    .{
                        .width = max_size.width,
                        .height = 1,
                    },
                )),
            });

            return .{
                .size = max_size,
                .widget = self.widget(),
                .buffer = &.{},
                .children = children.items,
            };
        }
    };
}
