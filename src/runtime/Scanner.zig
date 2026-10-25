//! Threaded Scanner: drives core.ScanEngine from a worker thread, owns all
//! filesystem access.

const std = @import("std");
const platform = @import("../platform.zig");
const ScanEngine = @import("../core/ScanEngine.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Scanner = @This();

pub const EntryId = ScanEngine.EntryId;
pub const ScanStats = ScanEngine.ScanStats;
pub const ListDirEntry = ScanEngine.ListDirEntry;
pub const DumpOptions = ScanEngine.DumpOptions;

_engine: *ScanEngine,
_thread: std.Thread,
_io: Io,

pub fn init(io: Io, allocator: Allocator, scanned_path: []const u8) !Scanner {
    const engine = try allocator.create(ScanEngine);
    errdefer allocator.destroy(engine);
    engine.* = try ScanEngine.init(allocator, io, scanned_path);
    errdefer engine.deinit(allocator);

    const thread = try std.Thread.spawn(.{}, workerFunc, .{ engine, allocator, io });

    return .{ ._engine = engine, ._thread = thread, ._io = io };
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
    return std.Io.Clock.awake.now(self._io).toMilliseconds();
}

/// Blocks until the engine is idle — the scan queue has drained (bounded by
/// `timeout_ms`). Repeatable: waits out later rescans too.
pub fn waitIdle(self: *Scanner, timeout_ms: u64) !void {
    return self.waitIdleTimeout(.{ .duration = .{
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
        .clock = .awake,
    } });
}

/// Blocks until the engine is idle; `.none` waits indefinitely.
pub fn waitIdleTimeout(self: *Scanner, timeout: std.Io.Timeout) !void {
    return self._engine.waitIdle(self._io, timeout);
}

/// Deletion runs on the worker thread in per-directory rounds, so the
/// tree keeps updating while it goes; the entry leaves the tree when
/// the deletion completes.
pub fn requestDelete(self: *Scanner, allocator: Allocator, parent: EntryId, name: []const u8) Allocator.Error!void {
    return self._engine.requestDelete(allocator, parent, name);
}

/// Moves the last deletion failure into `buf` (truncated to fit); null
/// when nothing failed since the previous call.
pub fn takeError(self: *Scanner, buf: []u8) ?[]const u8 {
    return self._engine.takeError(buf);
}

pub fn deinitListDir(allocator: Allocator, entries: *std.ArrayList(ListDirEntry)) void {
    ScanEngine.deinitListDir(allocator, entries);
}

/// Merges tree state with a fresh listing of the directory on disk. Fails
/// with `error.DirMissing` when the directory cannot be opened: it was
/// deleted (or became unreadable) while the view was inside it.
pub fn listDir(self: *Scanner, allocator: Allocator, dir_id: EntryId) !std.ArrayList(ListDirEntry) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const dir_path = try self._engine.pathOf(arena.allocator(), dir_id);
    const listing = try scanSingleDir(self._io, arena.allocator(), dir_path);
    if (listing.missing) return error.DirMissing;
    return self._engine.listDirMerged(allocator, arena.allocator(), dir_id, listing.entries);
}

/// Prints the scanned tree as `<size>\t<path>` lines.
pub fn dump(self: *Scanner, allocator: Allocator, writer: *std.Io.Writer, opts: DumpOptions) !void {
    return self._engine.dump(allocator, writer, opts);
}

fn workerFunc(engine: *ScanEngine, allocator: Allocator, io: Io) void {
    workerFuncErr(engine, allocator, io) catch |err| {
        std.log.err("Error: {any}", .{err});
    };
    engine.markIdle();
}

fn workerFuncErr(engine: *ScanEngine, allocator: Allocator, io: Io) !void {
    const scan_start_time = std.Io.Clock.awake.now(io);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // park when the queues are empty, serving user-requested deletions and
    // rescans until a stop is requested
    while (!engine.stopRequested()) {
        const job = engine.nextJob(allocator) orelse {
            io.sleep(.fromMicroseconds(100), .awake) catch {}; // 0.1ms
            continue;
        };

        _ = arena.reset(.retain_capacity);

        // Deletion failures are recorded in the engine's error slot by the
        // job itself; the errors that reach here are allocation failures,
        // which are as fatal as they are for scans.
        switch (job) {
            .scan => |scan| try runScanJob(engine, allocator, io, arena.allocator(), scan),
            .delete_dir => |dir| try runDeleteDirJob(engine, allocator, io, arena.allocator(), dir),
            .delete_file => |file| {
                defer allocator.free(file.name);
                try runDeleteFileJob(engine, allocator, io, arena.allocator(), file);
            },
        }
    }

    const c = engine.counters();
    const scan_millis: f64 = @floatFromInt(scan_start_time.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds());
    std.log.info(
        "Scan finished in {d:.2}s. Dirs: {d}. Files: {d}. Size: {d}",
        .{ scan_millis / 1000, c.dirs, c.files, c.scanned_size },
    );
}

const DirListing = struct {
    entries: []ScanEngine.DirEntry,
    /// The directory could not be opened: it does not exist (or became
    /// unreadable), as opposed to existing but being empty.
    missing: bool = false,
};

fn runScanJob(engine: *ScanEngine, allocator: Allocator, io: Io, arena: Allocator, scan: ScanEngine.ScanJob) !void {
    const dir_path = try engine.pathOf(arena, scan.id);
    const listing = try scanSingleDir(io, arena, dir_path);
    try engine.applyListing(allocator, arena, scan.id, listing.entries);
}

fn runDeleteDirJob(engine: *ScanEngine, allocator: Allocator, io: Io, arena: Allocator, dir: ScanEngine.DirJob) !void {
    const dir_path = try engine.pathOf(arena, dir.id);
    const listing = try scanSingleDir(io, arena, dir_path);

    var remaining: std.ArrayList(ScanEngine.DirEntry) = .empty;
    var deleted_any = false;
    for (listing.entries) |entry| {
        const target = try std.fs.path.join(arena, &.{ dir_path, entry.name });
        if (platform.deletePath(Io.Dir.cwd(), io, target)) {
            deleted_any = true;
        } else |err| switch (err) {
            // still has contents; its own delete job empties it later
            error.DirNotEmpty => try remaining.append(arena, entry),
            // vanished under us — counts as deleted
            error.FileNotFound => deleted_any = true,
            else => {
                engine.recordDeleteError(entry.name, err);
                // still on disk: kept in the round's listing so the tree
                // does not drop it, and the round counts as progress-less
                try remaining.append(arena, entry);
            },
        }
    }

    if (remaining.items.len > 0) {
        try engine.applyDeleteRound(allocator, arena, dir, remaining.items, deleted_any);
        return;
    }

    platform.deletePath(Io.Dir.cwd(), io, dir_path) catch |err| switch (err) {
        error.FileNotFound => {}, // already gone
        else => engine.recordDeleteError(std.fs.path.basename(dir_path), err),
    };
    // the parent's fresh listing drops this directory from the tree
    if (engine.getParentId(dir.id)) |parent| {
        try engine.pushJobs(allocator, &.{.{ .scan = .{ .id = parent } }});
    }
}

/// Unlinks the file, then syncs the parent's tree from a fresh listing.
fn runDeleteFileJob(engine: *ScanEngine, allocator: Allocator, io: Io, arena: Allocator, file: ScanEngine.FileJob) !void {
    const parent_path = try engine.pathOf(arena, file.parent);
    const listing = try scanSingleDir(io, arena, parent_path);

    var remaining: std.ArrayList(ScanEngine.DirEntry) = .empty;
    var found = false;
    for (listing.entries) |entry| {
        if (!found and std.mem.eql(u8, entry.name, file.name)) {
            found = true;
            const target = try std.fs.path.join(arena, &.{ parent_path, file.name });
            if (platform.deletePath(Io.Dir.cwd(), io, target)) {} else |err| switch (err) {
                // vanished under us; the sync below drops it either way
                error.FileNotFound => {},
                else => {
                    engine.recordDeleteError(file.name, err);
                    try remaining.append(arena, entry);
                },
            }
            continue;
        }
        try remaining.append(arena, entry);
    }
    if (!found) engine.recordDeleteError(file.name, error.FileNotFound);

    try engine.applyListing(allocator, arena, file.parent, remaining.items);
}

fn scanSingleDir(io: Io, arena: Allocator, dir_path: []const u8) !DirListing {
    var entries = std.ArrayList(ScanEngine.DirEntry).empty;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Failed to open `{s}`: {any}", .{ dir_path, err });
        return .{ .entries = entries.items, .missing = true };
    };
    defer dir.close(io);

    var it = dir.iterateAssumeFirstIteration();
    while (true) {
        const entry = it.next(io) catch |err| {
            std.log.warn("Failed to iterate in `{s}`: {any}", .{ dir_path, err });
            break;
        } orelse break;
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
                const stats = dir.statFile(io, entry.name, .{}) catch |err| {
                    std.log.warn("Failed to stat file `{s}/{s}`: {any}", .{ dir_path, entry.name, err });
                    continue;
                };
                try entries.append(arena, .{
                    .name = name,
                    .size = stats.size,
                    .kind = .file,
                });
            },
            // no stat: it would follow the link, and the link itself is
            // what deletions act on
            .sym_link => {
                try entries.append(arena, .{
                    .name = name,
                    .size = 0,
                    .kind = .sym_link,
                });
            },
            else => {},
        }
    }

    return .{ .entries = entries.items };
}

fn writeFixtureFile(dir: Io.Dir, sub_path: []const u8, size: usize) !void {
    const io = std.testing.io;
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    var f = try dir.createFile(io, sub_path, .{});
    defer f.close(io);
    var buf: [4096]u8 = @splat(0);
    var left = size;
    while (left > 0) {
        const n = @min(left, buf.len);
        try f.writeStreamingAll(io, buf[0..n]);
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

        const path = try tmpPath(gpa, &tmp);
        defer gpa.free(path);
        const scanner = try Scanner.init(std.testing.io, gpa, path);
        return .{ .tmp = tmp, .scanner = scanner };
    }

    fn destroy(self: *Fixture) !void {
        self.scanner.deinit(std.testing.allocator);
        self.tmp.cleanup();
    }
};

/// Absolute path of a testing.TmpDir without realpath: cwd plus the
/// `.zig-cache/tmp` prefix that tmpDir creates under.
fn tmpPath(allocator: Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    const cwd_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd_path);
    return std.fs.path.join(allocator, &.{ cwd_path, ".zig-cache", "tmp", &tmp.sub_path });
}

test "Scanner scans a fixture and reports totals" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

    const stats = try fixture.scanner.getStats(std.testing.allocator, .root);
    try std.testing.expectEqual(@as(u32, 3), stats.total_files);
    try std.testing.expectEqual(@as(u32, 2), stats.total_dirs);
    try std.testing.expectEqual(@as(u64, 350), stats.scanned_size);
    try std.testing.expectEqual(@as(u64, 350), stats.current_dir_size);
}

test "Scanner reports subdirectory stats" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

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
    try fixture.scanner.waitIdle(10_000);

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
    try fixture.scanner.waitIdle(10_000);

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
        std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        waited += 1;
    }
    try std.testing.expect(waited < 10_000);
}

test "Scanner.listDir reports a deleted directory" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

    var entries = try fixture.scanner.listDir(std.testing.allocator, .root);
    defer Scanner.deinitListDir(std.testing.allocator, &entries);
    const a_id = for (entries.items) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.name, "a")) break entry.id.?;
    } else return error.MissingDir;

    // delete it behind the scanner's back; the next listDir must report
    // the disappearance instead of pretending the directory is empty
    try fixture.tmp.dir.deleteTree(std.testing.io, "a");
    try std.testing.expectError(error.DirMissing, fixture.scanner.listDir(std.testing.allocator, a_id));
}

test "Scanner deletes a queued file and refreshes the tree" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

    try fixture.scanner.requestDelete(std.testing.allocator, .root, "root50.bin");
    try fixture.scanner.waitIdle(10_000);

    var entries = try fixture.scanner.listDir(std.testing.allocator, .root);
    defer Scanner.deinitListDir(std.testing.allocator, &entries);
    // parent row, then a/ (300 B): the deleted file is gone
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings(".", entries.items[0].name);
    try std.testing.expectEqualStrings("a", entries.items[1].name);

    const stats = try fixture.scanner.getStats(std.testing.allocator, .root);
    try std.testing.expectEqual(@as(u64, 300), stats.scanned_size);
    try std.testing.expectEqual(@as(u32, 2), stats.total_files);
}

test "Scanner deletes a queued directory tree and refreshes the tree" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

    try fixture.scanner.requestDelete(std.testing.allocator, .root, "a");
    try fixture.scanner.waitIdle(10_000);

    var entries = try fixture.scanner.listDir(std.testing.allocator, .root);
    defer Scanner.deinitListDir(std.testing.allocator, &entries);
    // parent row, then root50.bin (50 B): the whole subtree is gone
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("root50.bin", entries.items[1].name);

    const stats = try fixture.scanner.getStats(std.testing.allocator, .root);
    try std.testing.expectEqual(@as(u64, 50), stats.scanned_size);
    try std.testing.expectEqual(@as(u32, 1), stats.total_files);
    try std.testing.expectEqual(@as(u32, 0), stats.total_dirs);
}

test "Scanner deletes a leaf dir without touching its parent" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

    var entries = try fixture.scanner.listDir(std.testing.allocator, .root);
    defer Scanner.deinitListDir(std.testing.allocator, &entries);
    const a_id = for (entries.items) |entry| {
        if (entry.kind == .directory and std.mem.eql(u8, entry.name, "a")) break entry.id.?;
    } else return error.MissingDir;

    try fixture.scanner.requestDelete(std.testing.allocator, a_id, "b");
    try fixture.scanner.waitIdle(10_000);

    // a/ survives on disk and keeps its other file
    var a_entries = try fixture.scanner.listDir(std.testing.allocator, a_id);
    defer Scanner.deinitListDir(std.testing.allocator, &a_entries);
    try std.testing.expectEqual(@as(usize, 2), a_entries.items.len);
    try std.testing.expectEqualStrings("..", a_entries.items[0].name);
    try std.testing.expectEqualStrings("one.bin", a_entries.items[1].name);

    const stats = try fixture.scanner.getStats(std.testing.allocator, a_id);
    try std.testing.expectEqual(@as(u64, 100), stats.current_dir_size);

    // and b/ is really gone from disk while its parent still exists
    try std.testing.expectError(error.FileNotFound, fixture.tmp.dir.openDir(std.testing.io, "a/b", .{}));
}

test "Scanner records a failure when a delete misses" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

    try fixture.scanner.requestDelete(std.testing.allocator, .root, "no-such.bin");
    try fixture.scanner.waitIdle(10_000);

    var buf: [256]u8 = undefined;
    const msg = fixture.scanner.takeError(&buf);
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.startsWith(u8, msg.?, "Failed to delete 'no-such.bin'"));
    try std.testing.expect(fixture.scanner.takeError(&buf) == null);
}

test "Scanner deletes a directory whose contents are symlinks" {
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

    const base = try tmpPath(std.testing.allocator, &fixture.tmp);
    defer std.testing.allocator.free(base);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const stuck = try std.mem.print(&buf, "{s}/a/stuck", .{base});
    try Io.Dir.cwd().createDir(std.testing.io, stuck, .default_dir);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.mem.print(&link_buf, "{s}/a/stuck/LICENSE", .{base});
    const linkz = try std.testing.allocator.dupeSentinel(u8, link, 0);
    defer std.testing.allocator.free(linkz);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink("../nowhere", linkz));

    try fixture.scanner.requestDelete(std.testing.allocator, .root, "a");
    // converges instead of cycling
    try fixture.scanner.waitIdle(10_000);

    var ebuf: [256]u8 = undefined;
    try std.testing.expect(fixture.scanner.takeError(&ebuf) == null);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openDir(std.testing.io, stuck, .{}));
}

test "delete rounds give up when a directory cannot empty" {
    // root ignores directory permissions, so the lock would not hold
    if (std.os.linux.getuid() == 0) return error.SkipZigTest;
    var fixture = try Fixture.create();
    defer fixture.destroy() catch {};
    try fixture.scanner.waitIdle(10_000);

    try writeFixtureFile(fixture.tmp.dir, "locked/keep.bin", 10);
    const base = try tmpPath(std.testing.allocator, &fixture.tmp);
    defer std.testing.allocator.free(base);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const locked = try std.mem.print(&buf, "{s}/locked", .{base});
    const lockedz = try std.testing.allocator.dupeSentinel(u8, locked, 0);
    defer std.testing.allocator.free(lockedz);
    // no write permission: nothing inside can be unlinked
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(lockedz, 0o555));
    defer {
        // restore write permission so the TmpDir cleanup can delete the tree
        std.testing.expectEqual(@as(c_int, 0), std.c.chmod(lockedz, 0o755)) catch {};
    }

    // a listing teaches the tree about the new directory (and its file)
    var entries = try fixture.scanner.listDir(std.testing.allocator, .root);
    defer Scanner.deinitListDir(std.testing.allocator, &entries);
    try fixture.scanner.waitIdle(10_000);

    try fixture.scanner.requestDelete(std.testing.allocator, .root, "locked");
    // terminates instead of cycling, and the failure is reported
    try fixture.scanner.waitIdle(10_000);

    var ebuf: [256]u8 = undefined;
    const msg = fixture.scanner.takeError(&ebuf);
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "locked") != null);

    const stats = try fixture.tmp.dir.statFile(std.testing.io, "locked/keep.bin", .{});
    try std.testing.expectEqual(@as(u64, 10), stats.size);
}

test "Scanner deinit stops a running scan" {
    var fixture = try Fixture.create();
    // no waitIdle: deinit must join the worker thread promptly from any state
    try fixture.destroy();
}
