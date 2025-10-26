const std = @import("std");
const clap = @import("clap");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Scanner = @import("Scanner.zig");
const AppView = @import("ui/AppView.zig");
const main = @import("main.zig");

const Allocator = std.mem.Allocator;

pub fn run(allocator: Allocator) !u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\--no-ui                Run without UI. Performs scan of specified path and prints results
        \\<str>                  Path to scan.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stdout(), err);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(.stdout(), clap.Help, &params, .{});
        return 0;
    }

    const scanned_path = if (res.positionals[0]) |arg| blk: {
        break :blk arg;
    } else {
        std.log.err("Path parameter is required", .{});
        return 1;
    };

    {
        var dir = std.fs.cwd().openDir(scanned_path, .{}) catch |err| {
            std.log.err("Can't open dir {s}: {any}", .{ scanned_path, err });
            return 1;
        };
        dir.close();
    }

    if (res.args.@"no-ui" != 0) {
        try run_without_ui(allocator, scanned_path);
        return 0;
    }

    main.allow_log.store(false, .seq_cst);
    defer main.allow_log.store(true, .seq_cst);

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    const window = try allocator.create(AppView);
    defer allocator.destroy(window);
    window.* = try AppView.init(allocator, scanned_path);
    defer window.deinit();

    try app.run(window.widget(), .{});

    return 0;
}

fn run_without_ui(allocator: Allocator, scanned_path: []const u8) !void {
    var scanner = try Scanner.init(allocator, scanned_path);
    defer scanner.deinit(allocator);
    while (scanner.isScanning()) {
        std.Thread.sleep(100_000);
    }
}
