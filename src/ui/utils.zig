const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn nameToUtf8(allocator: Allocator, bytes: []const u8) ![]const u8 {
    var new_bytes = std.ArrayList(u8).empty;
    try new_bytes.ensureTotalCapacity(allocator, bytes.len);

    var pos: usize = 0;
    while (pos < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch {
            try new_bytes.appendSlice(allocator, "�");
            pos += 1;
            continue;
        };
        if (pos + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[pos .. pos + len])) {
            try new_bytes.appendSlice(allocator, bytes[pos .. pos + len]);
        } else {
            try new_bytes.appendSlice(allocator, "�");
        }
        pos += len;
    }

    return new_bytes.toOwnedSlice(allocator);
}

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

test "nameToUtf8 passes valid text and replaces invalid bytes" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "abc", .want = "abc" },
        .{ .in = "héllo", .want = "héllo" },
        .{ .in = "a\xffb", .want = "a\u{FFFD}b" },
        .{ .in = "a\xc3", .want = "a\u{FFFD}" },
        .{ .in = "\xff\xfe", .want = "\u{FFFD}\u{FFFD}" },
    };
    for (cases) |case| {
        const got = try nameToUtf8(gpa, case.in);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}
