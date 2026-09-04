const builtin = @import("builtin");
const std = @import("std");
const process = std.process;
const Io = std.Io;

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

fn usage() noreturn {
    std.debug.print("Usage: unzip [-d DIR] ZIP_FILE\n", .{});
    std.process.exit(1);
}

pub fn main(init: process.Init) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const io = init.io;

    var cmdline_opt: struct {
        dir_arg: ?[]const u8 = null,
    } = .{};

    var non_option_args: std.ArrayList([]const u8) = .empty;
    {
        var it = try process.Args.Iterator.initAllocator(init.minimal.args, arena);
        _ = it.next(); // argv[0]
        while (it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                try non_option_args.append(arena, arg);
            } else if (std.mem.eql(u8, arg, "-d")) {
                const next = it.next() orelse fatal("option '{s}' requires an argument", .{arg});
                cmdline_opt.dir_arg = next;
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
    }

    if (non_option_args.items.len != 1) usage();
    const zip_file_arg = non_option_args.items[0];

    const cwd = Io.Dir.cwd();
    var out_dir = blk: {
        if (cmdline_opt.dir_arg) |dir| {
            break :blk cwd.openDir(io, dir, .{}) catch |err| switch (err) {
                error.FileNotFound => blk2: {
                    try cwd.createDirPath(io, dir);
                    break :blk2 try cwd.openDir(io, dir, .{});
                },
                else => fatal("failed to open output directory '{s}' with {s}", .{ dir, @errorName(err) }),
            };
        }
        break :blk cwd;
    };
    defer if (cmdline_opt.dir_arg != null) out_dir.close(io);

    const zip_file = cwd.openFile(io, zip_file_arg, .{}) catch |err|
        fatal("open '{s}' failed: {s}", .{ zip_file_arg, @errorName(err) });
    defer zip_file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = zip_file.reader(io, &buf);
    try std.zip.extract(out_dir, &fr, .{
        .allow_backslashes = true,
    });
}
