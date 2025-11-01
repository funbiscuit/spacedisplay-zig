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
