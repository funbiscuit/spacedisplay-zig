//! Size formatting shared by other modules.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn formatSize(allocator: Allocator, bytes: u64, width: comptime_int) ![]const u8 {
    const units = [_][]const u8{ "B  ", "KiB", "MiB", "GiB", "TiB" };
    var unit: usize = 0;
    var fb: f64 = @floatFromInt(bytes);
    while (unit + 1 < units.len and fb > 999) {
        unit += 1;
        fb /= 1024.0;
    }
    if (fb > 999) {
        return try std.fmt.allocPrint(allocator, ">999 {s}", .{units[unit]});
    } else {
        var num_bytes: [16]u8 = undefined;
        const precision: u8 = if (fb > 99) 0 else if (fb > 9) 1 else 2;
        var num_str = std.fmt.bufPrint(&num_bytes, "{d:.[1]}", .{ fb, precision }) catch unreachable;

        if (precision > 0) {
            while (num_str[num_str.len - 1] == '0') {
                num_str = num_str[0 .. num_str.len - 1];
            }
            if (num_str[num_str.len - 1] == '.') {
                num_str = num_str[0 .. num_str.len - 1];
            }
        }

        return try std.fmt.allocPrint(allocator, "{s: >[2]} {s}", .{ num_str, units[unit], width });
    }
}

test "formatSize picks units and precision" {
    const gpa = std.testing.allocator;
    inline for (.{
        .{ 0, 4, "   0 B  " },
        .{ 999, 4, " 999 B  " },
        .{ 1000, 4, "0.98 KiB" },
        .{ 1024, 4, "   1 KiB" },
        .{ 5 * 1024 * 1024, 4, "   5 MiB" },
        .{ 2 * 1024 * 1024 * 1024 * 1024, 4, "   2 TiB" },
        .{ 2000 * 1024 * 1024 * 1024 * 1024, 4, ">999 TiB" },
        .{ 5 * 1024 * 1024, 0, "5 MiB" },
    }) |case| {
        const got = try formatSize(gpa, case[0], case[1]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case[2], got);
    }
}

test "formatSize strips trailing zeros" {
    const gpa = std.testing.allocator;
    const got = try formatSize(gpa, 10 * 1024, 4);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("  10 KiB", got);
}
