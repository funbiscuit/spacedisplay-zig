//! Threaded Scanner: drives core.ScanEngine from a worker thread, owns all
//! filesystem access.

const std = @import("std");
const platform = @import("../platform.zig");
const ScanEngine = @import("../core/ScanEngine.zig");

const Allocator = std.mem.Allocator;
const Scanner = @This();

pub const EntryId = ScanEngine.EntryId;
pub const ScanStats = ScanEngine.ScanStats;
pub const ListDirEntry = ScanEngine.ListDirEntry;
pub const DumpOptions = ScanEngine.DumpOptions;

_engine: *ScanEngine,
_thread: std.Thread,

pub fn init(allocator: Allocator, scanned_path: []const u8) !Scanner {
    const engine = try allocator.create(ScanEngine);
    errdefer allocator.destroy(engine);
    engine.* = try ScanEngine.init(allocator, scanned_path);
    errdefer engine.deinit(allocator);

    const thread = try std.Thread.spawn(.{}, workerFunc, .{ engine, allocator });

    return .{ ._engine = engine, ._thread = thread };
}

pub fn deinit(self: *Scanner, allocator: Allocator) void {
    self._engine.requestStop();
    self._thread.join();
    self._engine.deinit(allocator);
    allocator.destroy(self._engine);
}

pub fn getStats(self: *Scanner, allocator: Allocator, dir_id: EntryId) !ScanStats {
    const mount = try platform.getMountStats(allocator, self._engine.scannedPath());
    return self._engine.getStats(dir_id, mount);
}

pub fn getParentId(self: *Scanner, id: EntryId) ?EntryId {
    return self._engine.getParentId(id);
}

pub fn isScanning(self: *Scanner) bool {
    return self._engine.isScanning();
}

pub fn hasChanges(self: *Scanner) bool {
    return self._engine.hasChanges();
}

pub fn getEntryPath(self: *Scanner, allocator: Allocator, id: EntryId) ![]const u8 {
    return self._engine.pathOf(allocator, id);
}

pub fn getScannedChildId(self: *Scanner, parent: EntryId) ?EntryId {
    return self._engine.getScannedChildId(parent);
}

/// Wall clock for the UI (spinner animation, update throttling).
pub fn nowMs(self: *Scanner) i64 {
    _ = self;
    return std.time.milliTimestamp();
}

pub fn deinitListDir(allocator: Allocator, entries: *std.ArrayList(ListDirEntry)) void {
    ScanEngine.deinitListDir(allocator, entries);
}

/// Merges tree state with a fresh listing of the directory on disk.
pub fn listDir(self: *Scanner, allocator: Allocator, dir_id: EntryId) !std.ArrayList(ListDirEntry) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const dir_path = try self._engine.pathOf(arena.allocator(), dir_id);
    const entries = try scanSingleDir(arena.allocator(), dir_path);
    return self._engine.listDirMerged(allocator, arena.allocator(), dir_id, entries);
}

/// Prints the scanned tree as `<size>\t<path>` lines.
pub fn dump(self: *Scanner, allocator: Allocator, writer: *std.Io.Writer, opts: DumpOptions) !void {
    return self._engine.dump(allocator, writer, opts);
}

fn workerFunc(engine: *ScanEngine, allocator: Allocator) void {
    workerFuncErr(engine, allocator) catch |err| {
        std.log.err("Error: {any}", .{err});
    };
    engine.markIdle();
}

fn workerFuncErr(engine: *ScanEngine, allocator: Allocator) !void {
    const scan_start_time = std.time.milliTimestamp();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // park when the queues are empty, serving user-requested rescans until
    // a stop is requested
    while (!engine.stopRequested()) {
        const id = engine.nextDirToScan() orelse {
            std.Thread.sleep(100_000); // 0.1ms
            continue;
        };

        _ = arena.reset(.retain_capacity);

        const dir_path = try engine.pathOf(allocator, id);
        defer allocator.free(dir_path);

        const entries = try scanSingleDir(arena.allocator(), dir_path);
        try engine.applyListing(allocator, arena.allocator(), id, entries);
    }

    const c = engine.counters();
    const scan_millis: f64 = @floatFromInt(std.time.milliTimestamp() - scan_start_time);
    std.log.info(
        "Scan finished in {d:.2}s. Dirs: {d}. Files: {d}. Size: {d}",
        .{ scan_millis / 1000, c.dirs, c.files, c.scanned_size },
    );
}

fn scanSingleDir(arena: Allocator, dir_path: []const u8) ![]ScanEngine.DirEntry {
    var entries = std.ArrayList(ScanEngine.DirEntry).empty;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Failed to open `{s}`: {any}", .{ dir_path, err });
        return entries.items;
    };
    defer dir.close();

    var it = dir.iterateAssumeFirstIteration();
    while (it.next()) |maybe_entry| {
        const entry = maybe_entry orelse break;
        const name = try arena.dupe(u8, entry.name);
        switch (entry.kind) {
            .directory => {
                const can_scan = try platform.canScan(arena, dir_path, name);
                try entries.append(arena, .{
                    .name = name,
                    .size = 0,
                    .kind = .directory,
                    .can_scan = can_scan,
                });
            },
            .file => {
                const stats = dir.statFile(entry.name) catch |err| {
                    std.log.warn("Failed to stat file `{s}/{s}`: {any}", .{ dir_path, entry.name, err });
                    continue;
                };
                try entries.append(arena, .{
                    .name = name,
                    .size = stats.size,
                    .kind = .file,
                });
            },
            else => {},
        }
    } else |err| {
        std.log.warn("Failed to iterate in `{s}`: {any}", .{ dir_path, err });
    }

    return entries.items;
}

fn waitIdle(scanner: *Scanner, timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (scanner.isScanning()) {
        if (waited >= timeout_ms) return error.ScanTimeout;
        std.Thread.sleep(std.time.ns_per_ms);
        waited += 1;
    }
}

fn writeFixtureFile(dir: std.fs.Dir, sub_path: []const u8, size: usize) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.makePath(parent);
    var f = try dir.createFile(sub_path, .{});
    defer f.close();
    var buf = [_]u8{0} ** 4096;
    var left = size;
    while (left > 0) {
        const n = @min(left, buf.len);
        try f.writeAll(buf[0..n]);
        left -= n;
    }
}

// Fixture used by the tests below
//TODO not really a unit test, refactor later into e2e test
const Fixture = struct {
    tmp: std.testing.TmpDir,
    scanner: Scanner,

    fn create() !Fixture {
        const gpa = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try writeFixtureFile(tmp.dir, "root50.bin", 50);
        try writeFixtureFile(tmp.dir, "a/one.bin", 100);
        try writeFixtureFile(tmp.dir, "a/b/two.bin", 200);

        const path = try tmp.dir.realpathAlloc(gpa, ".");
        defer gpa.free(path);
        const scanner = try Scanner.init(gpa, path);
        return .{ .tmp = tmp, .scanner = scanner };
    }

    fn destroy(self: *Fixture) !void {
        self.scanner.deinit(std.testing.allocator);
        self.tmp.cleanup();
    }
};

test "Scanner scans a fixture and reports totals" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try waitIdle(&fixture.scanner, 10_000);

    const stats = try fixture.scanner.getStats(std.testing.allocator, .root);
    try std.testing.expectEqual(@as(u32, 3), stats.total_files);
    try std.testing.expectEqual(@as(u32, 2), stats.total_dirs);
    try std.testing.expectEqual(@as(u64, 350), stats.scanned_size);
    try std.testing.expectEqual(@as(u64, 350), stats.current_dir_size);
}

test "Scanner reports subdirectory stats" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try waitIdle(&fixture.scanner, 10_000);

    var entries = try fixture.scanner.listDir(std.testing.allocator, .root);
    defer Scanner.deinitListDir(std.testing.allocator, &entries);
    const a_id = for (entries.items) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.name, "a")) break entry.id.?;
    } else return error.MissingDir;

    const stats = try fixture.scanner.getStats(std.testing.allocator, a_id);
    try std.testing.expectEqual(@as(u64, 300), stats.current_dir_size);
}

test "Scanner listDir merges tree with disk state" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try waitIdle(&fixture.scanner, 10_000);

    var entries = try fixture.scanner.listDir(std.testing.allocator, .root);
    defer Scanner.deinitListDir(std.testing.allocator, &entries);

    // parent first, then sorted by size: a/ (300 B), root50.bin (50 B);
    // at root the parent entry is named "." instead of ".."
    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    try std.testing.expectEqualStrings(".", entries.items[0].name);
    try std.testing.expectEqualStrings("a", entries.items[1].name);
    try std.testing.expectEqual(@as(u64, 300), entries.items[1].size);
    try std.testing.expect(entries.items[1].id != null);
    try std.testing.expectEqualStrings("root50.bin", entries.items[2].name);
    try std.testing.expectEqual(@as(u64, 50), entries.items[2].size);

    // tree ids let the UI navigate without touching the filesystem again
    const a_id = entries.items[1].id.?;
    try std.testing.expect(fixture.scanner.getParentId(a_id).?.eql(.root));

    var a_entries = try fixture.scanner.listDir(std.testing.allocator, a_id);
    defer Scanner.deinitListDir(std.testing.allocator, &a_entries);
    try std.testing.expectEqual(@as(usize, 3), a_entries.items.len);
    try std.testing.expectEqualStrings("..", a_entries.items[0].name);
    try std.testing.expectEqualStrings("b", a_entries.items[1].name);
    try std.testing.expectEqual(@as(u64, 200), a_entries.items[1].size);
    try std.testing.expectEqualStrings("one.bin", a_entries.items[2].name);
}

test "Scanner processes queued rescans after the scan settles" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try waitIdle(&fixture.scanner, 10_000);

    // grow the fixture behind the scanner's back; the next listDir notices
    // the mismatch and queues a rescan for the parked worker
    try writeFixtureFile(fixture.tmp.dir, "new/later.bin", 40);
    var entries = try fixture.scanner.listDir(std.testing.allocator, .root);
    defer Scanner.deinitListDir(std.testing.allocator, &entries);
    const listed_id = for (entries.items) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.name, "new")) break entry.id;
    } else return error.MissingDir;
    try std.testing.expect(listed_id == null);

    // bounded wait: only the worker's applyListing can attach a tree id
    var waited: u64 = 0;
    while (waited < 10_000) {
        var after = try fixture.scanner.listDir(std.testing.allocator, .root);
        defer Scanner.deinitListDir(std.testing.allocator, &after);
        const id = for (after.items) |entry| {
            if (entry.kind == .directory and std.mem.eql(u8, entry.name, "new")) break entry.id;
        } else null;
        if (id != null) break;
        std.Thread.sleep(std.time.ns_per_ms);
        waited += 1;
    }
    try std.testing.expect(waited < 10_000);
}

test "Scanner deinit stops a running scan" {
    var fixture = try Fixture.create();
    // no waitIdle: deinit must join the worker thread promptly from any state
    try fixture.destroy();
}
