const std = @import("std");
const clap = @import("clap");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Scanner = @import("runtime/Scanner.zig");
const AppView = @import("ui/app_view.zig").AppView;
const logging = @import("logging.zig");
const build_info = @import("build_info");

const Allocator = std.mem.Allocator;

pub fn run(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const io = init.io;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                    Display this help and exit.
        \\--no-ui                       Run without UI. Performs scan of specified path and exits
        \\--print                       With --no-ui: print scanned tree with directory sizes to stdout
        \\--max-depth <u32>             With --print: limit dump depth (default: unlimited)
        \\--min-size <u64>              With --print: skip directories smaller than this size in bytes
        \\-V, --version                 Print version information and quit
        \\<str>                         Path to scan.
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stdout(), err);
        return 1;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        try clap.helpToFile(io, .stdout(), clap.Help, &params, .{});
        return 0;
    }

    if (res.args.version != 0) {
        try printVersion(io);
        return 0;
    }

    const scanned_path = if (res.positionals[0]) |arg| blk: {
        break :blk arg;
    } else {
        std.log.err("Path parameter is required", .{});
        return 1;
    };

    {
        var dir = std.Io.Dir.cwd().openDir(io, scanned_path, .{}) catch |err| {
            std.log.err("Can't open dir {s}: {any}", .{ scanned_path, err });
            return 1;
        };
        dir.close(io);
    }

    if (res.args.@"no-ui" != 0 or res.args.print != 0) {
        try run_without_ui(allocator, io, scanned_path, .{
            .print = res.args.print != 0,
            .max_depth = res.args.@"max-depth" orelse std.math.maxInt(u32),
            .min_size = res.args.@"min-size" orelse 0,
        });
        return 0;
    }

    logging.allow_log.store(false, .seq_cst);
    defer logging.allow_log.store(true, .seq_cst);

    // The tty's write buffer; must outlive the app.
    var tty_buffer: [4096]u8 = undefined;
    var app = try vxfw.App.init(io, allocator, init.environ_map, &tty_buffer);
    defer app.deinit();

    var scanner = try Scanner.init(io, allocator, scanned_path);
    defer scanner.deinit(allocator);

    const window = try allocator.create(AppView(Scanner));
    defer allocator.destroy(window);
    window.* = try AppView(Scanner).init(allocator, &scanner);
    defer window.deinit();

    try app.run(window.widget(), .{});

    return 0;
}

fn run_without_ui(allocator: Allocator, io: std.Io, scanned_path: []const u8, opts: PrintOptions) !void {
    var scanner = try Scanner.init(io, allocator, scanned_path);
    defer scanner.deinit(allocator);
    try scanner.waitIdleTimeout(.none);

    if (opts.print) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
        try scanner.dump(allocator, &stdout_writer.interface, .{
            .max_depth = opts.max_depth,
            .min_size = opts.min_size,
        });
        try stdout_writer.interface.flush();
    }
}

const PrintOptions = struct {
    print: bool,
    max_depth: u32,
    min_size: u64,
};

fn printVersion(io: std.Io) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);

    try writer.interface.print("{s} {s}\n", .{ @tagName(build_info.name), build_info.version });
    return writer.interface.flush();
}
