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
