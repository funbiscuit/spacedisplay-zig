//! Scripted UI data provider: a threadless ScanEngine over a fake disk,
//! plus a fake clock.

const std = @import("std");
const spacedisplay = @import("spacedisplay");

const ScanEngine = spacedisplay.core.ScanEngine;
const Allocator = std.mem.Allocator;

pub const TestCtx = struct {
    pub const EntryId = ScanEngine.EntryId;
    pub const ListDirEntry = ScanEngine.ListDirEntry;
    pub const ScanStats = ScanEngine.ScanStats;
    pub const DirEntry = ScanEngine.DirEntry;

    /// One fake directory: its path and what "ls" returns for it.
    pub const Disk = struct {
        path: []const u8,
        entries: []const DirEntry,
    };

    _engine: ScanEngine,

    /// The fake disk, consulted by scans and listDir calls.
    disk: []const Disk = &.{},
    /// Fake wall clock returned by nowMs.
    now_ms: i64 = 0,
    /// When set, reported by getScannedChildId (drives the spinner).
    scanned_child: ?EntryId = null,

    /// Scans the fake disk synchronously, so tests start with a fully
    /// scanned tree. The engine root is "/base".
    pub fn init(gpa: Allocator, disk: []const Disk) !TestCtx {
        var scan_engine = try ScanEngine.init(gpa, "/base");
        errdefer scan_engine.deinit(gpa);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        while (scan_engine.nextDirToScan()) |id| {
            const path = try scan_engine.pathOf(arena.allocator(), id);
            try scan_engine.applyListing(gpa, arena.allocator(), id, entriesFor(disk, path));
        }

        return .{ ._engine = scan_engine, .disk = disk };
    }

    fn entriesFor(disk: []const Disk, path: []const u8) []const DirEntry {
        for (disk) |d| {
            if (std.mem.eql(u8, d.path, path)) return d.entries;
        }
        return &.{};
    }

    pub fn deinit(self: *TestCtx, gpa: Allocator) void {
        self._engine.deinit(gpa);
    }

    pub fn engine(self: *TestCtx) *ScanEngine {
        return &self._engine;
    }

    pub fn listDir(self: *TestCtx, gpa: Allocator, dir_id: EntryId) !std.ArrayList(ListDirEntry) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        const path = try self._engine.pathOf(arena.allocator(), dir_id);
        return self._engine.listDirMerged(gpa, arena.allocator(), dir_id, entriesFor(self.disk, path));
    }

    pub fn deinitListDir(gpa: Allocator, entries: *std.ArrayList(ListDirEntry)) void {
        ScanEngine.deinitListDir(gpa, entries);
    }

    pub fn getParentId(self: *TestCtx, id: EntryId) ?EntryId {
        return self._engine.getParentId(id);
    }

    pub fn getScannedChildId(self: *TestCtx, parent: EntryId) ?EntryId {
        if (self.scanned_child) |id| {
            if (self._engine.getParentId(id)) |p| {
                if (p.eql(parent)) return id;
            }
        }
        return null;
    }

    pub fn hasChanges(self: *TestCtx) bool {
        return self._engine.hasChanges();
    }

    pub fn nowMs(self: *TestCtx) i64 {
        return self.now_ms;
    }

    pub fn getStats(self: *TestCtx, gpa: Allocator, dir_id: EntryId) !ScanStats {
        _ = gpa;
        return self._engine.getStats(dir_id, null);
    }

    pub fn getEntryPath(self: *TestCtx, gpa: Allocator, id: EntryId) ![]const u8 {
        return self._engine.pathOf(gpa, id);
    }
};
