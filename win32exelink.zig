const builtin = @import("builtin");
const std = @import("std");
const process = std.process;
const Io = std.Io;

const log = std.log.scoped(.zigexelink);

// NOTE: to prevent the exe from having multiple markers, I can't create a separate string literal
//       for the marker and get the length from that, I have to hardcode the length
const exe_marker_len = 42;

// I'm exporting this and making it mutable to make sure the compiler keeps it around
// and prevent it from evaluting its contents at comptime
export var zig_exe_string: [exe_marker_len + std.fs.max_path_bytes + 1]u8 =
    ("!!!THIS MARKS THE zig_exe_string MEMORY!!#" ++ ([1]u8{0} ** (std.fs.max_path_bytes + 1))).*;

const global = struct {
    var io: Io = undefined;
    var child: ?process.Child = null;
};

pub fn main(init: process.Init) !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const io = init.io;
    global.io = io;

    // Sanity check that the exe_marker_len is right (note: not fullproof)
    std.debug.assert(zig_exe_string[exe_marker_len - 1] == '#');
    if (zig_exe_string[exe_marker_len] == 0) {
        log.err("the zig target executable has not been set in the exelink", .{});
        return 0xff; // fail
    }
    var zig_exe_len: usize = 1;
    while (zig_exe_string[exe_marker_len + zig_exe_len] != 0) {
        zig_exe_len += 1;
        if (exe_marker_len + zig_exe_len > std.fs.max_path_bytes) {
            log.err("the zig target execuable is either too big (over {}) or the exe is corrupt", .{std.fs.max_path_bytes});
            return 1;
        }
    }
    const zig_exe = zig_exe_string[exe_marker_len .. exe_marker_len + zig_exe_len :0];

    var argv: std.ArrayList([]const u8) = .empty;
    {
        // NOTE: initAllocator is REQUIRED on Windows (plain .init
        // compile-errors there).
        var it = try process.Args.Iterator.initAllocator(init.minimal.args, arena);
        var first = true;
        while (it.next()) |a| {
            if (first) {
                first = false;
                try argv.append(arena, zig_exe); // replace argv[0]
                continue;
            }
            try argv.append(arena, a);
        }
    }

    if (argv.items.len >= 2 and std.mem.eql(u8, argv.items[1], "exelink")) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var out_file = Io.File.stdout();
        var w = out_file.writerStreaming(io, &buf);
        try w.interface.writeAll(zig_exe);
        try w.interface.flush();
        return 0;
    }

    var child = process.spawn(io, .{
        .argv = argv.items,
        .environ_map = null,
    }) catch |err| {
        log.err("failed to spawn '{s}': {s}", .{ zig_exe, @errorName(err) });
        return 0xff;
    };

    // NOTE: create the process before calling SetConsoleCtrlHandler because the handler uses it
    global.child = child;

    if (0 == win32.SetConsoleCtrlHandler(consoleCtrlHandler, 1)) {
        log.err("SetConsoleCtrlHandler failed, error={}", .{@intFromEnum(win32.GetLastError())});
        return 0xff; // fail
    }

    const term = child.wait(io) catch |err| {
        log.err("failed waiting on '{s}': {s}", .{ zig_exe, @errorName(err) });
        return 0xff;
    };
    return switch (term) {
        .exited => |e| e,
        else => 0xff,
    };
}

fn consoleCtrlHandler(ctrl_type: u32) callconv(.c) win32.BOOL {
    //
    // NOTE: Do I need to synchronize this with the main thread?
    //
    const name: []const u8 = switch (ctrl_type) {
        win32.CTRL_C_EVENT => "Control-C",
        win32.CTRL_BREAK_EVENT => "Break",
        win32.CTRL_CLOSE_EVENT => "Close",
        win32.CTRL_LOGOFF_EVENT => "Logoff",
        win32.CTRL_SHUTDOWN_EVENT => "Shutdown",
        else => "Unknown",
    };
    // TODO: should we stop the process on a break event?
    log.info("caught ctrl signal {d} ({s}), stopping process...", .{ ctrl_type, name });
    if (global.child) |*child| {
        child.kill(global.io);
    }
    std.process.exit(0xff);
}
const win32 = struct {
    pub const BOOL = i32;
    pub const CTRL_C_EVENT = @as(u32, 0);
    pub const CTRL_BREAK_EVENT = @as(u32, 1);
    pub const CTRL_CLOSE_EVENT = @as(u32, 2);
    pub const CTRL_LOGOFF_EVENT = @as(u32, 5);
    pub const CTRL_SHUTDOWN_EVENT = @as(u32, 6);
    pub const GetLastError = std.os.windows.GetLastError;
    pub const PHANDLER_ROUTINE = *const fn (
        CtrlType: u32,
    ) callconv(.c) BOOL;
    pub extern "kernel32" fn SetConsoleCtrlHandler(
        HandlerRoutine: ?PHANDLER_ROUTINE,
        Add: BOOL,
    ) callconv(.c) BOOL;
};
