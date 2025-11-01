const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Scanner = @import("../Scanner.zig");

const FilesView = @import("FilesView.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const ProgressBar = @This();

stats: Scanner.ScanStats,

pub fn widget(self: *const ProgressBar) vxfw.Widget {
    return .{
        .userdata = @constCast(self),
        .drawFn = ProgressBar.typeErasedDrawFn,
    };
}

fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
    const self: *const ProgressBar = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *const ProgressBar, ctx: vxfw.DrawContext) !vxfw.Surface {
    const max_size = ctx.max.size();

    var children = std.ArrayList(vxfw.SubSurface).empty;

    const files_text = try std.fmt.allocPrint(ctx.arena, " {d} files ", .{self.stats.total_files});
    const files_widget: vxfw.Text = .{ .text = files_text };

    try children.append(ctx.arena, .{
        .origin = .{ .row = 0, .col = 0 },
        .surface = try files_widget.draw(ctx),
    });

    const bar_width = max_size.width -| @as(u16, @intCast(files_text.len));
    const bar_items = try createBars(ctx.arena, self.stats);
    makeLayout(bar_items, bar_width);

    var pos: i17 = @intCast(files_text.len);
    for (bar_items) |item| {
        if (item.width) |width| {
            const surf = try vxfw.Surface.init(
                ctx.arena,
                self.widget(),
                .{ .width = width, .height = 1 },
            );
            //TODO use bar symbol for smoother update
            for (0..width) |i| {
                surf.writeCell(@intCast(i), 0, .{
                    .char = .{},
                    .style = item.style,
                });
            }

            const label: vxfw.Text = .{
                .text = item.label,
                .style = item.style,
            };
            const label_offset: i17 = @intCast((width -| item.label.len) / 2);

            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = pos },
                .surface = surf,
            });
            try children.append(ctx.arena, .{
                .origin = .{ .row = 0, .col = pos + label_offset },
                .surface = try label.draw(ctx),
            });
            pos +|= @intCast(width);
        }
    }

    return .{
        .size = max_size,
        .widget = self.widget(),
        .buffer = &.{},
        .children = children.items,
    };
}

const BarItem = struct {
    label: []const u8,
    weight: f64,
    style: vaxis.Style = .{},
    width: ?u16 = null,
};

fn makeLayout(items: []BarItem, width: u16) void {
    var total_weight: f64 = 0;
    var str_width: u16 = 0;
    for (items) |item| {
        total_weight += item.weight;
        str_width += @intCast(item.label.len + 2);
    }
    if (width <= str_width) {
        // don't have enough space, so just use min sizes
        for (items) |*item| {
            item.width = @intCast(item.label.len + 2);
        }
    }

    var width_available: f64 = 0.0;
    var total_width: f64 = 0;
    const layout_width: f64 = @floatFromInt(width);

    for (items) |*item| {
        const desired_width = @round((layout_width * item.weight / total_weight));
        const min_width: f64 = @floatFromInt(item.label.len + 2);
        const item_width = @max(min_width, desired_width);
        if (item_width > min_width) {
            width_available += item_width - min_width;
        }
        total_width += item_width;
        item.width = @intFromFloat(item_width);
    }
    var overdraw = total_width - layout_width;

    for (items) |*item| {
        //SAFETY: width is set in previous loop for all items
        const item_width = item.width.?;
        const available: u16 = item_width - @as(u16, @intCast(item.label.len + 2));

        if (available > 0) {
            const favailable: f64 = @floatFromInt(available);
            const sub = @min(@round(favailable / width_available * overdraw), favailable);
            width_available -= favailable;
            overdraw -= sub;
            if (sub < 0) {
                item.width = item_width + @as(u16, @intFromFloat(-sub));
            } else {
                item.width = item_width - @as(u16, @intFromFloat(sub));
            }
        }
    }
}

fn createBars(arena: Allocator, stats: Scanner.ScanStats) ![]BarItem {
    var scanned_dir_str: []const u8 = "";
    var scanned_dir_weight: f64 = 0;
    var remaining_str: []const u8 = "";
    var remaining_weight: f64 = 0;

    if (stats.current_dir_size != 0 and stats.current_dir_size != stats.scanned_size) {
        scanned_dir_str = try utils.formatSize(arena, stats.current_dir_size, 0);
        scanned_dir_weight = @floatFromInt(stats.current_dir_size);
        const remaining = stats.scanned_size -| stats.current_dir_size;
        if (remaining > 0) {
            remaining_weight = @floatFromInt(remaining);
            remaining_str = try utils.formatSize(arena, remaining, 0);
        }
    } else if (stats.scanned_size > 0) {
        scanned_dir_str = try utils.formatSize(arena, stats.scanned_size, 0);
        scanned_dir_weight = @floatFromInt(stats.scanned_size);
    }

    var children = std.ArrayList(BarItem).empty;

    if (scanned_dir_str.len > 0) {
        try children.append(arena, .{
            .label = scanned_dir_str,
            .weight = scanned_dir_weight,
            .style = .{ .bg = .{ .index = 4 } },
        });
    }
    if (remaining_str.len > 0) {
        try children.append(arena, .{
            .label = remaining_str,
            .weight = remaining_weight,
            .style = .{ .bg = .{ .index = 6 } },
        });
    }
    if (stats.unknown_size > 0) {
        try children.append(arena, .{
            .label = try utils.formatSize(arena, stats.unknown_size, 0),
            .weight = if (stats.is_mount_point) @floatFromInt(stats.unknown_size) else 1,
            .style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 7 } },
        });
    }
    if (stats.available_size > 0) {
        try children.append(arena, .{
            .label = try utils.formatSize(arena, stats.available_size, 0),
            .weight = if (stats.is_mount_point) @floatFromInt(stats.available_size) else 1,
            .style = .{ .bg = .{ .index = 2 } },
        });
    }
    return children.items;
}
