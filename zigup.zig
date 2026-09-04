const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Io = std.Io;
const process = std.process;

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const fixdeletetree = @import("fixdeletetree.zig");
const lanes = @import("lanes.zig");

const arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    .arm => "armv7a",
    .powerpc64 => "powerpc64",
    .powerpc64le => "powerpc64le",
    .riscv64 => "riscv64",
    .s390x => "s390x",
    .x86 => "x86",
    .x86_64 => "x86_64",
    else => @compileError("Unsupported CPU Architecture"),
};
const os = switch (builtin.os.tag) {
    .freebsd => "freebsd",
    .linux => "linux",
    .macos => "macos",
    .netbsd => "netbsd",
    .windows => "windows",
    else => @compileError("Unsupported OS"),
};
const os_arch = os ++ "-" ++ arch;
const arch_os = arch ++ "-" ++ os;
const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

// Stashed by main() — single-threaded CLI; 0.16-final std threads an `Io`
// handle (and the environ map) through every operation instead.
var g_io: Io = undefined;
var g_gpa: Allocator = undefined;
var g_env: *const process.Environ.Map = undefined;
var g_lane_ctx: lanes.Ctx = undefined;

var global_override_appdata: ?[]const u8 = null; // only used for testing
var global_optional_install_dir: ?[]const u8 = null;
var global_optional_path_link: ?[]const u8 = null;

var global_enable_log = true;
fn loginfo(comptime fmt: []const u8, args: anytype) void {
    if (global_enable_log) {
        std.debug.print(fmt ++ "\n", args);
    }
}

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

const DownloadResult = union(enum) {
    ok: void,
    err: []u8,
    pub fn deinit(self: DownloadResult, allocator: Allocator) void {
        switch (self) {
            .ok => {},
            .err => |e| allocator.free(e),
        }
    }
};
fn download(allocator: Allocator, url: []const u8, writer: *Io.Writer) DownloadResult {
    var client = std.http.Client{ .allocator = allocator, .io = g_io };
    defer client.deinit();

    var fetch_result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = writer,
    }) catch |err| return .{ .err = std.fmt.allocPrint(
        allocator,
        "failed to download '{s}' with {s}",
        .{ url, @errorName(err) },
    ) catch |e| oom(e) };

    if (fetch_result.status != .ok) return .{ .err = std.fmt.allocPrint(
        allocator,
        "the HTTP server replied with unsuccessful response '{d} {s}'",
        .{ @intFromEnum(fetch_result.status), fetch_result.status.phrase() orelse "" },
    ) catch |e| oom(e) };

    return .ok;
}

const DownloadStringResult = union(enum) {
    ok: []u8,
    err: []u8,
};
fn downloadToString(allocator: Allocator, url: []const u8) DownloadStringResult {
    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    switch (download(allocator, url, &aw.writer)) {
        .ok => return .{ .ok = aw.toOwnedSlice() catch |e| oom(e) },
        .err => |e| return .{ .err = e },
    }
}

fn allocInstallDirStringXdg(allocator: Allocator) error{AlreadyReported}![]const u8 {
    // see https://specifications.freedesktop.org/basedir-spec/latest/#variables
    // try $XDG_DATA_HOME/zigup first
    xdg_var: {
        const xdg_data_home = g_env.get("XDG_DATA_HOME") orelse break :xdg_var;
        if (xdg_data_home.len == 0) break :xdg_var;
        if (!std.fs.path.isAbsolute(xdg_data_home)) {
            std.log.err("$XDG_DATA_HOME environment variable '{s}' is not an absolute path", .{xdg_data_home});
            return error.AlreadyReported;
        }
        return std.fs.path.join(allocator, &[_][]const u8{ xdg_data_home, "zigup" }) catch |e| oom(e);
    }
    // .. then fallback to $HOME/.local/share/zigup
    const home = g_env.get("HOME") orelse {
        std.log.err("cannot find install directory, neither $HOME nor $XDG_DATA_HOME environment variables are set", .{});
        return error.AlreadyReported;
    };
    if (!std.fs.path.isAbsolute(home)) {
        std.log.err("$HOME environment variable '{s}' is not an absolute path", .{home});
        return error.AlreadyReported;
    }
    return std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "share", "zigup" }) catch |e| oom(e);
}

/// The settings dir is shared with the lane machinery (one file layout):
/// `--appdata` (tests) > $ZIGUP_SETTINGS|$ZLANE_SETTINGS > platform
/// (%LOCALAPPDATA%\zigup on Windows, ~/Library/Application Support/zigup on
/// macOS, $XDG_CONFIG_HOME|~/.config/zigup elsewhere).
fn getSettingsDir(allocator: Allocator) ?[]const u8 {
    _ = allocator;
    if (global_override_appdata) |appdata_override| return appdata_override;
    return lanes.settingsDir(g_lane_ctx) catch null;
}

/// Absolute directory of this executable, derived from argv[0] — anchored
/// on the cwd because fs.path.resolve can return a RELATIVE path when fed
/// relative inputs (0.16-final std has no selfExe API).
fn selfExeDir() ?[]const u8 {
    const argv0 = g_lane_ctx.argv0;
    const cwd = process.currentPathAlloc(g_io, g_gpa) catch return null;
    const abs = if (std.fs.path.isAbsolute(argv0))
        argv0
    else
        std.fs.path.resolve(g_gpa, &.{ cwd, argv0 }) catch return null;
    const d = std.fs.path.dirname(abs) orelse return null;
    if (d.len == 0) return null;
    var dir = d;
    while (dir.len > 1 and (dir[dir.len - 1] == '/' or dir[dir.len - 1] == '\\')) dir = dir[0 .. dir.len - 1];
    return dir;
}

fn readFileSetting(allocator: Allocator, path: []const u8, max: usize, what: []const u8) !?[]const u8 {
    const content = blk: {
        var file = Io.Dir.cwd().openFile(g_io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| {
                std.log.err("open '{s}' failed with {s}", .{ path, @errorName(e) });
                return error.AlreadyReported;
            },
        };
        defer file.close(g_io);
        var buf: [1]u8 = undefined;
        var fr = file.reader(g_io, &buf);
        break :blk fr.interface.allocRemaining(allocator, .limited(max)) catch |err| {
            std.log.err("read {s} from '{s}' failed with {s}", .{ what, path, @errorName(err) });
            return error.AlreadyReported;
        };
    };
    return content;
}

fn readInstallDir(allocator: Allocator) !?[]const u8 {
    const settings_dir_path = getSettingsDir(allocator) orelse return null;
    const setting_path = std.fs.path.join(allocator, &.{ settings_dir_path, "install-dir" }) catch |e| oom(e);
    const content = (try readFileSetting(allocator, setting_path, 9999, "install dir")) orelse return null;

    const stripped = std.mem.trimEnd(u8, content, " \r\n");

    if (!std.fs.path.isAbsolute(stripped)) {
        std.log.err("install directory '{s}' is not an absolute path, fix this by running `zigup set-install-dir`", .{stripped});
        return error.BadInstallDirSetting;
    }

    return stripped;
}

fn saveInstallDir(allocator: Allocator, maybe_dir: ?[]const u8) !void {
    const settings_dir_path = getSettingsDir(allocator) orelse {
        std.log.err("cannot save install dir, unable to find a suitable settings directory", .{});
        return error.AlreadyReported;
    };
    const setting_path = std.fs.path.join(allocator, &.{ settings_dir_path, "install-dir" }) catch |e| oom(e);
    if (maybe_dir) |d| {
        try Io.Dir.cwd().createDirPath(g_io, settings_dir_path);

        {
            var file = try Io.Dir.cwd().createFile(g_io, setting_path, .{ .truncate = true });
            defer file.close(g_io);
            var fw = file.writerStreaming(g_io, &.{});
            try fw.interface.writeAll(d);
            try fw.interface.flush();
        }

        // sanity check, read it back
        const readback = (try readInstallDir(allocator)) orelse {
            std.log.err("unable to readback install-dir after saving it", .{});
            return error.AlreadyReported;
        };
        if (!std.mem.eql(u8, readback, d)) {
            std.log.err("saved install dir readback mismatch\nwrote: '{s}'\nread : '{s}'\n", .{ d, readback });
            return error.AlreadyReported;
        }
    } else {
        Io.Dir.cwd().deleteFile(g_io, setting_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
    }
}

fn getBuiltinInstallDir(allocator: Allocator) error{AlreadyReported}![]const u8 {
    if (builtin.os.tag == .windows) {
        const self_exe_dir = selfExeDir() orelse {
            std.log.err("failed to determine this executable's directory from argv[0]", .{});
            return error.AlreadyReported;
        };
        return std.fs.path.join(allocator, &.{ self_exe_dir, "zig" }) catch |e| oom(e);
    }
    return allocInstallDirStringXdg(allocator);
}

fn allocInstallDirString(allocator: Allocator) error{ AlreadyReported, BadInstallDirSetting }![]const u8 {
    if (try readInstallDir(allocator)) |d| return d;
    return try getBuiltinInstallDir(allocator);
}
const GetInstallDirOptions = struct {
    create: bool,
    log: bool = true,
};
fn getInstallDir(allocator: Allocator, options: GetInstallDirOptions) ![]const u8 {
    var optional_dir_to_free_on_error: ?[]const u8 = null;
    errdefer if (optional_dir_to_free_on_error) |dir| allocator.free(dir);

    const install_dir = init: {
        if (global_optional_install_dir) |dir| break :init dir;
        optional_dir_to_free_on_error = try allocInstallDirString(allocator);
        break :init optional_dir_to_free_on_error.?;
    };
    std.debug.assert(std.fs.path.isAbsolute(install_dir));
    if (options.log) {
        loginfo("install directory '{s}'", .{install_dir});
    }
    if (options.create) {
        loggyMakePath(install_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
    return install_dir;
}

fn makeZigPathLinkString(allocator: Allocator) ![]const u8 {
    if (global_optional_path_link) |path| return path;

    const zigup_dir = selfExeDir() orelse return error.SelfExeDirUnavailable;

    return try std.fs.path.join(allocator, &[_][]const u8{ zigup_dir, comptime "zig" ++ builtin.target.exeFileExt() });
}

// TODO: this should be in standard lib somewhere
fn toAbsolute(allocator: Allocator, path: []const u8) ![]u8 {
    std.debug.assert(!std.fs.path.isAbsolute(path));
    const cwd = try process.currentPathAlloc(g_io, allocator);
    return std.fs.path.join(allocator, &[_][]const u8{ cwd, path });
}

fn help(allocator: Allocator) !void {
    const builtin_install_dir = getBuiltinInstallDir(allocator) catch |err| switch (err) {
        error.AlreadyReported => "unknown (see error printed above)",
    };
    const current_install_dir = allocInstallDirString(allocator) catch |err| switch (err) {
        error.AlreadyReported => "unknown (see error printed above)",
        error.BadInstallDirSetting => "invalid (fix with zigup set-install-dir)",
    };
    const setting_file: []const u8 = blk: {
        if (getSettingsDir(allocator)) |d| break :blk std.fs.path.join(allocator, &.{ d, "install-dir" }) catch |e| oom(e);
        break :blk "unavailable";
    };

    std.debug.print(
        \\Download and manage zig compilers.
        \\
        \\Common Usage:
        \\
        \\  zigup VERSION                 download and set VERSION compiler as default
        \\  zigup fetch VERSION           download VERSION compiler
        \\  zigup default [VERSION]       get or set the default compiler
        \\  zigup list                    list installed compiler versions
        \\  zigup clean   [VERSION]       deletes the given compiler version, otherwise, cleans all compilers
        \\                                that aren't the default, master, or marked to keep.
        \\  zigup keep VERSION            mark a compiler to be kept during clean
        \\  zigup run VERSION ARGS...     run the given VERSION of the compiler with the given ARGS...
        \\                                (with no installed VERSION, `run` acts as the `zig` shim instead)
        \\
        \\Lanes (multiple named compiler lines on one machine):
        \\
        \\  zigup lane set <name> <dir>   register lane <name> backed by a toolchain dir
        \\  zigup lane list               list lanes
        \\  zigup lane remove <name>      remove a lane
        \\  zigup lane shim [name]...     install lane shims (incl. `zig`) next to zigup
        \\  zigup which | path            what `zig` resolves to, and why
        \\  zigup doctor                  diagnose the whole zig setup (lanes, PATH, env)
        \\  zigup run [args...]           act as the `zig` shim (when args[0] is not an
        \\                                installed compiler version)
        \\
        \\                                `zig` resolution: ./.ziglane (cwd and ancestors)
        \\                                  > $ZIGUP_LANE > zig on PATH (project-first, NO
        \\                                  machine-wide default; $ZIGUP_LANE=path skips lanes;
        \\                                  an explicit pin that is broken is an error, never
        \\                                  a substitution)
        \\
        \\  zigup get-install-dir         prints the install directory to stdout
        \\  zigup set-install-dir [PATH]  set the default install directory, omitting the PATH reverts to the builtin default
        \\                                current default: {s}
        \\                                setting file   : {s}
        \\                                builtin default: {s}
        \\
        \\Uncommon Usage:
        \\
        \\  zigup fetch-index             download and print the download index json
        \\
        \\Common Options:
        \\  --install-dir DIR             override the default install location
        \\  --path-link PATH              path to the `zig` symlink that points to the default compiler
        \\                                this will typically be a file path within a PATH directory so
        \\                                that the user can just run `zig`
        \\  --index                       override the default index URL that zig versions/URLs are fetched from.
        \\                                default:
    ++ " " ++ default_index_url ++
        \\
        \\
    ,
        .{
            current_install_dir,
            setting_file,
            builtin_install_dir,
        },
    );
}

fn getCmdOpt(args: [][]const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* == args.len) {
        std.log.err("option '{s}' requires an argument", .{args[i.* - 1]});
        return error.AlreadyReported;
    }
    return args[i.*];
}

pub fn main(init: process.Init) !u8 {
    // Arena over page memory: a short-lived CLI that never frees. (The
    // process.Init gpa is a DebugAllocator that leak-reports at exit —
    // noise for a run-and-exit tool.)
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    g_gpa = allocator;
    g_io = init.io;
    g_env = init.environ_map;

    var it = try process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    const argv0 = it.next() orelse {
        std.debug.print("zigup: no argv[0]\n", .{});
        return 0xff;
    };
    var args_array: ArrayList([]const u8) = .empty;
    try args_array.append(allocator, argv0);
    while (it.next()) |a| try args_array.append(allocator, a);

    var prog = std.fs.path.basename(argv0);
    if (std.mem.endsWith(u8, prog, ".exe")) prog = prog[0 .. prog.len - 4];
    g_lane_ctx = .{
        .io = init.io,
        .gpa = allocator,
        .env = init.environ_map,
        .argv0 = argv0,
        .prog = prog,
        .appdata_override = null,
    };

    return main2(allocator, args_array.items) catch |e| switch (e) {
        error.AlreadyReported => return 1,
        else => return e,
    };
}
pub fn main2(allocator: Allocator, args_array: []const []const u8) !u8 {
    wsaStartupIfWindows();

    // lane shims (zig, zig_ccached, vigz, ...) dispatch before CLI parsing
    // so that compiler args pass through untouched
    const args_with_argv0: [][]const u8 = @constCast(args_array);
    if (args_with_argv0.len >= 1) {
        if (try lanes.shimDispatch(g_lane_ctx, args_with_argv0[1..])) |code| return code;
    }

    var args = if (args_array.len == 0) args_with_argv0 else args_with_argv0[1..];
    // parse common options

    var index_url: []const u8 = default_index_url;

    {
        var i: usize = 0;
        var newlen: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "--install-dir", arg)) {
                global_optional_install_dir = try getCmdOpt(args, &i);
                if (!std.fs.path.isAbsolute(global_optional_install_dir.?)) {
                    global_optional_install_dir = try toAbsolute(allocator, global_optional_install_dir.?);
                }
            } else if (std.mem.eql(u8, "--path-link", arg)) {
                global_optional_path_link = try getCmdOpt(args, &i);
                if (!std.fs.path.isAbsolute(global_optional_path_link.?)) {
                    global_optional_path_link = try toAbsolute(allocator, global_optional_path_link.?);
                }
            } else if (std.mem.eql(u8, "--index", arg)) {
                index_url = try getCmdOpt(args, &i);
            } else if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
                try help(allocator);
                return 0;
            } else if (std.mem.eql(u8, "--appdata", arg)) {
                // NOTE: this is a private option just used for testing
                global_override_appdata = try getCmdOpt(args, &i);
                g_lane_ctx.appdata_override = global_override_appdata;
            } else {
                if (newlen == 0 and std.mem.eql(u8, "run", arg)) {
                    return try runSubcommand(allocator, args[i + 1 ..]);
                }
                args[newlen] = args[i];
                newlen += 1;
            }
        }
        args = args[0..newlen];
    }
    if (args.len == 0) {
        try help(allocator);
        return 1;
    }
    // lane management / diagnostics subcommands
    if (std.mem.eql(u8, "lane", args[0]) or std.mem.eql(u8, "lanes", args[0])) {
        return try lanes.cli(g_lane_ctx, args[1..]);
    }
    if (std.mem.eql(u8, "doctor", args[0]) or std.mem.eql(u8, "which", args[0]) or
        std.mem.eql(u8, "path", args[0]))
    {
        return try lanes.cli(g_lane_ctx, args);
    }
    if (std.mem.eql(u8, "get-install-dir", args[0])) {
        if (args.len != 1) {
            std.log.err("get-install-dir does not accept any cmdline arguments", .{});
            return 1;
        }
        const install_dir = getInstallDir(allocator, .{ .create = false, .log = false }) catch |err| switch (err) {
            error.AlreadyReported => return 1,
            else => |e| return e,
        };
        try Io.File.stdout().writeStreamingAll(g_io, install_dir);
        try Io.File.stdout().writeStreamingAll(g_io, "\n");
        return 0;
    }
    if (std.mem.eql(u8, "set-install-dir", args[0])) {
        const set_args = args[1..];
        switch (set_args.len) {
            0 => try saveInstallDir(allocator, null),
            1 => {
                const path = set_args[0];
                if (!std.fs.path.isAbsolute(path)) {
                    std.log.err("set-install-dir requires an absolute path", .{});
                    return 1;
                }
                try saveInstallDir(allocator, path);
            },
            else => |set_arg_count| {
                std.log.err("set-install-dir requires 0 or 1 cmdline arg but got {}", .{set_arg_count});
                return 1;
            },
        }
        return 0;
    }
    if (std.mem.eql(u8, "fetch-index", args[0])) {
        if (args.len != 1) {
            std.log.err("'index' command requires 0 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        var download_index = try fetchDownloadIndex(allocator, index_url);
        defer download_index.deinit(allocator);
        try Io.File.stdout().writeStreamingAll(g_io, download_index.text);
        return 0;
    }
    if (std.mem.eql(u8, "fetch", args[0])) {
        if (args.len != 2) {
            std.log.err("'fetch' command requires 1 argument but got {d}", .{args.len - 1});
            return 1;
        }
        try fetchCompiler(allocator, index_url, args[1], .leave_default);
        return 0;
    }
    if (std.mem.eql(u8, "clean", args[0])) {
        if (args.len == 1) {
            try cleanCompilers(allocator, null);
        } else if (args.len == 2) {
            try cleanCompilers(allocator, args[1]);
        } else {
            std.log.err("'clean' command requires 0 or 1 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, "keep", args[0])) {
        if (args.len != 2) {
            std.log.err("'keep' command requires 1 argument but got {d}", .{args.len - 1});
            return 1;
        }
        try keepCompiler(allocator, args[1]);
        return 0;
    }
    if (std.mem.eql(u8, "list", args[0])) {
        if (args.len != 1) {
            std.log.err("'list' command requires 0 arguments but got {d}", .{args.len - 1});
            return 1;
        }
        try listCompilers(allocator);
        return 0;
    }
    if (std.mem.eql(u8, "default", args[0])) {
        if (args.len == 1) {
            try printDefaultCompiler(allocator);
            return 0;
        }
        if (args.len == 2) {
            const version_string = args[1];
            const install_dir_string = try getInstallDir(allocator, .{ .create = true });
            defer allocator.free(install_dir_string);
            const resolved_version_string = init_resolved: {
                if (!std.mem.eql(u8, version_string, "master"))
                    break :init_resolved version_string;

                const optional_master_dir: ?[]const u8 = blk: {
                    var install_dir = Io.Dir.openDirAbsolute(g_io, install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
                        error.FileNotFound => break :blk null,
                        else => return e,
                    };
                    defer install_dir.close(g_io);
                    break :blk try getMasterDir(allocator, &install_dir);
                };
                // no need to free master_dir, this is a short lived program
                break :init_resolved optional_master_dir orelse {
                    std.log.err("master has not been fetched", .{});
                    return 1;
                };
            };
            const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir_string, resolved_version_string });
            defer allocator.free(compiler_dir);
            try setDefaultCompiler(allocator, compiler_dir, .verify_existence);
            return 0;
        }
        std.log.err("'default' command requires 1 or 2 arguments but got {d}", .{args.len - 1});
        return 1;
    }
    if (args.len == 1) {
        try fetchCompiler(allocator, index_url, args[0], .set_default);
        return 0;
    }
    const command = args[0];
    std.log.err("command not impl '{s}'", .{command});
    return 1;
}

/// `zigup run ...` — stock behavior (run an installed VERSION from the
/// zigup pool) when the first word names an installed compiler; otherwise
/// exactly what the `zig` shim would do (lane resolution).
fn runSubcommand(allocator: Allocator, rest: []const []const u8) !u8 {
    if (rest.len >= 1) {
        if (getInstallDir(allocator, .{ .create = false, .log = false })) |install_dir_string| {
            const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir_string, rest[0] });
            if (existsAbsolute(compiler_dir) catch false) return try runCompiler(allocator, rest);
        } else |_| {}
    }
    return try lanes.runAsZig(g_lane_ctx, rest);
}

/// 0.16-final removed std.os.windows.WSAStartup; the new Io uses NTDLL
/// sockets directly, but initializing winsock anyway is harmless insurance
/// for any libc/winsock path still taken (e.g. TLS).
fn wsaStartupIfWindows() void {
    if (builtin.os.tag != .windows) return;
    const ws2_32 = struct {
        const WSADATA = extern struct {
            wVersion: u16,
            wHighVersion: u16,
            iMaxSockets: u16,
            iMaxUdpDg: u16,
            lpVendorInfo: ?*u8 = null,
            szDescription: [257]u8 = undefined,
            szSystemStatus: [129]u8 = undefined,
        };
        pub extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.c) i32;
    };
    var data: ws2_32.WSADATA = .{};
    _ = ws2_32.WSAStartup(0x0202, &data);
}

pub fn runCompiler(allocator: Allocator, args: []const []const u8) !u8 {
    // disable log so we don't add extra output to whatever the compiler will output
    global_enable_log = false;
    if (args.len <= 1) {
        std.log.err("zigup run requires at least 2 arguments: zigup run VERSION PROG ARGS...", .{});
        return 1;
    }
    const version_string = args[0];
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);

    const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir_string, version_string });
    defer allocator.free(compiler_dir);
    if (!try existsAbsolute(compiler_dir)) {
        std.log.err("compiler '{s}' does not exist, fetch it first with: zigup fetch {0s}", .{version_string});
        return 1;
    }

    var argv: ArrayList([]const u8) = .empty;
    try argv.append(allocator, try std.fs.path.join(allocator, &[_][]const u8{ compiler_dir, "files", comptime "zig" ++ builtin.target.exeFileExt() }));
    try argv.appendSlice(allocator, args[1..]);

    var child = process.spawn(g_io, .{
        .argv = argv.items,
        .environ_map = null,
    }) catch |err| {
        std.log.err("failed to spawn compiler: {s}", .{@errorName(err)});
        return 0xff;
    };
    const ret_val = child.wait(g_io) catch |err| {
        std.log.err("failed waiting on compiler: {s}", .{@errorName(err)});
        return 0xff;
    };
    switch (ret_val) {
        .exited => |code| return code,
        else => |result| {
            std.log.err("compiler exited with {t}", .{result});
            return 0xff;
        },
    }
}

const SetDefault = enum { set_default, leave_default };

fn fetchCompiler(
    allocator: Allocator,
    index_url: []const u8,
    version_arg: []const u8,
    set_default: SetDefault,
) !void {
    const install_dir = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir);

    var optional_download_index: ?DownloadIndex = null;
    // This is causing an LLVM error
    //defer if (optionalDownloadIndex) |_| optionalDownloadIndex.?.deinit(allocator);
    // Also I would rather do this, but it doesn't work because of const issues
    //defer if (optionalDownloadIndex) |downloadIndex| downloadIndex.deinit(allocator);

    const VersionUrl = struct { version: []const u8, url: []const u8 };

    // NOTE: we only fetch the download index if the user wants to download 'master', we can skip
    //       this step for all other versions because the version to URL mapping is fixed (see getDefaultUrl)
    const is_master = std.mem.eql(u8, version_arg, "master");
    const version_url = blk: {
        // For default index_url we can build the url so we avoid downloading the index
        if (!is_master and std.mem.eql(u8, default_index_url, index_url))
            break :blk VersionUrl{ .version = version_arg, .url = try getDefaultUrl(allocator, version_arg) };
        optional_download_index = try fetchDownloadIndex(allocator, index_url);
        const master = optional_download_index.?.json.value.object.get(version_arg).?;
        const compiler_version = master.object.get("version").?.string;
        const master_linux = master.object.get(arch_os).?;
        const master_linux_tarball = master_linux.object.get("tarball").?.string;
        break :blk VersionUrl{ .version = compiler_version, .url = master_linux_tarball };
    };
    const compiler_dir = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, version_url.version });
    defer allocator.free(compiler_dir);
    try installCompiler(allocator, compiler_dir, version_url.url);
    if (is_master) {
        const master_symlink = try std.fs.path.join(allocator, &[_][]const u8{ install_dir, "master" });
        defer allocator.free(master_symlink);
        if (builtin.os.tag == .windows) {
            var file = try Io.Dir.createFileAbsolute(g_io, master_symlink, .{ .truncate = true });
            defer file.close(g_io);
            var fw = file.writerStreaming(g_io, &.{});
            try fw.interface.writeAll(version_url.version);
            try fw.interface.flush();
        } else {
            _ = try loggyUpdateSymlink(version_url.version, master_symlink, .{ .is_directory = true });
        }
    }
    if (set_default == .set_default) {
        try setDefaultCompiler(allocator, compiler_dir, .existence_verified);
    }
}

const default_index_url = "https://ziglang.org/download/index.json";

const DownloadIndex = struct {
    text: []u8,
    json: std.json.Parsed(std.json.Value),
    pub fn deinit(self: *DownloadIndex, allocator: Allocator) void {
        self.json.deinit();
        allocator.free(self.text);
    }
};

fn fetchDownloadIndex(allocator: Allocator, index_url: []const u8) !DownloadIndex {
    const text = switch (downloadToString(allocator, index_url)) {
        .ok => |text| text,
        .err => |err| {
            std.log.err("could not download '{s}': {s}", .{ index_url, err });
            return error.AlreadyReported;
        },
    };
    errdefer allocator.free(text);
    var json = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch |e| {
        std.log.err(
            "failed to parse JSON content from index url '{s}' with {s}",
            .{ index_url, @errorName(e) },
        );
        return error.AlreadyReported;
    };
    errdefer json.deinit();
    return DownloadIndex{ .text = text, .json = json };
}

fn loggyMakePath(dir_absolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        loginfo("mkdir \"{s}\"", .{dir_absolute});
    } else {
        loginfo("mkdir -p '{s}'", .{dir_absolute});
    }
    try Io.Dir.cwd().createDirPath(g_io, dir_absolute);
}

fn loggyDeleteTreeAbsolute(dir_absolute: []const u8) !void {
    if (builtin.os.tag == .windows) {
        loginfo("rd /s /q \"{s}\"", .{dir_absolute});
    } else {
        loginfo("rm -rf '{s}'", .{dir_absolute});
    }
    try fixdeletetree.deleteTreeAbsolute(g_io, dir_absolute);
}

pub fn loggyRenameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    loginfo("mv '{s}' '{s}'", .{ old_path, new_path });
    try Io.Dir.renameAbsolute(old_path, new_path, g_io);
}

pub fn loggySymlinkAbsolute(target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) !void {
    loginfo("ln -s '{s}' '{s}'", .{ target_path, sym_link_path });
    // NOTE: symLinkAbsolute asserts the target is absolute, but the `master`
    //       link target is deliberately relative; the cwd handle accepts
    //       absolute link paths.
    try Io.Dir.cwd().symLink(g_io, target_path, sym_link_path, flags);
}

/// returns: true if the symlink was updated, false if it was already set to the given `target_path`
pub fn loggyUpdateSymlink(target_path: []const u8, sym_link_path: []const u8, flags: Io.Dir.SymLinkFlags) !bool {
    var current_target_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (Io.Dir.readLinkAbsolute(g_io, sym_link_path, &current_target_path_buffer)) |len| {
        const current_target_path = current_target_path_buffer[0..len];
        if (std.mem.eql(u8, target_path, current_target_path)) {
            loginfo("symlink '{s}' already points to '{s}'", .{ sym_link_path, target_path });
            return false; // already up-to-date
        }
        Io.Dir.cwd().deleteFile(g_io, sym_link_path) catch {};
    } else |e| switch (e) {
        error.FileNotFound => {},
        error.NotLink => {
            std.debug.print(
                "unable to update/overwrite the 'zig' PATH symlink, the file '{s}' already exists and is not a symlink\n",
                .{sym_link_path},
            );
            std.process.exit(1);
        },
        else => return e,
    }
    try loggySymlinkAbsolute(target_path, sym_link_path, flags);
    return true; // updated
}

// TODO: this should be in std lib somewhere
fn existsAbsolute(absolutePath: []const u8) !bool {
    Io.Dir.cwd().access(g_io, absolutePath, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        else => return e,
    };
    return true;
}

fn listCompilers(allocator: Allocator) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = false });
    defer allocator.free(install_dir_string);

    var install_dir = Io.Dir.openDirAbsolute(g_io, install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close(g_io);

    var buf: [256]u8 = undefined;
    var stdout_file = Io.File.stdout();
    var w = stdout_file.writerStreaming(g_io, &buf);
    const stdout = &w.interface;
    {
        var it = install_dir.iterate();
        while (try it.next(g_io)) |entry| {
            if (entry.kind != .directory)
                continue;
            if (std.mem.endsWith(u8, entry.name, ".installing"))
                continue;
            try stdout.print("{s}\n", .{entry.name});
        }
        try stdout.flush();
    }
}

fn keepCompiler(allocator: Allocator, compiler_version: []const u8) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);

    var install_dir = try Io.Dir.openDirAbsolute(g_io, install_dir_string, .{ .iterate = true });
    defer install_dir.close(g_io);

    var compiler_dir = install_dir.openDir(g_io, compiler_version, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("compiler not found: {s}", .{compiler_version});
            return error.AlreadyReported;
        },
        else => return e,
    };
    defer compiler_dir.close(g_io);
    var keep_fd = try compiler_dir.createFile(g_io, "keep", .{});
    keep_fd.close(g_io);
    loginfo("created '{s}{c}{s}{c}{s}'", .{ install_dir_string, std.fs.path.sep, compiler_version, std.fs.path.sep, "keep" });
}

fn cleanCompilers(allocator: Allocator, compiler_name_opt: ?[]const u8) !void {
    const install_dir_string = try getInstallDir(allocator, .{ .create = true });
    defer allocator.free(install_dir_string);
    // getting the current compiler
    const default_comp_opt = try getDefaultCompiler(allocator);
    defer if (default_comp_opt) |default_compiler| allocator.free(default_compiler);

    var install_dir = Io.Dir.openDirAbsolute(g_io, install_dir_string, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer install_dir.close(g_io);
    const master_points_to_opt = try getMasterDir(allocator, &install_dir);
    defer if (master_points_to_opt) |master_points_to| allocator.free(master_points_to);
    if (compiler_name_opt) |compiler_name| {
        if (getKeepReason(master_points_to_opt, default_comp_opt, compiler_name)) |reason| {
            std.log.err("cannot clean '{s}' ({s})", .{ compiler_name, reason });
            return error.AlreadyReported;
        }
        loginfo("deleting '{s}{c}{s}'", .{ install_dir_string, std.fs.path.sep, compiler_name });
        try fixdeletetree.deleteTree(install_dir, g_io, compiler_name);
    } else {
        var it = install_dir.iterate();
        while (try it.next(g_io)) |entry| {
            if (entry.kind != .directory)
                continue;
            if (getKeepReason(master_points_to_opt, default_comp_opt, entry.name)) |reason| {
                loginfo("keeping '{s}' ({s})", .{ entry.name, reason });
                continue;
            }

            {
                var compiler_dir = try install_dir.openDir(g_io, entry.name, .{});
                defer compiler_dir.close(g_io);
                if (compiler_dir.access(g_io, "keep", .{})) |_| {
                    loginfo("keeping '{s}' (has keep file)", .{entry.name});
                    continue;
                } else |e| switch (e) {
                    error.FileNotFound => {},
                    else => return e,
                }
            }
            loginfo("deleting '{s}{c}{s}'", .{ install_dir_string, std.fs.path.sep, entry.name });
            try fixdeletetree.deleteTree(install_dir, g_io, entry.name);
        }
    }
}
fn readDefaultCompiler(allocator: Allocator, buffer: *[std.fs.max_path_bytes + 1]u8) !?[]const u8 {
    const path_link = try makeZigPathLinkString(allocator);
    defer allocator.free(path_link);

    if (builtin.os.tag == .windows) {
        var file = Io.Dir.openFileAbsolute(g_io, path_link, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close(g_io);
        const len = try file.readPositionalAll(g_io, buffer, win32exelink.exe_offset);
        if (len != buffer.len) {
            std.log.err("path link file '{s}' is too small", .{path_link});
            return error.AlreadyReported;
        }
        const target_exe = std.mem.sliceTo(buffer, 0);
        return try allocator.dupe(u8, targetPathToVersion(target_exe));
    }

    const target_len = Io.Dir.readLinkAbsolute(g_io, path_link, buffer[0..std.fs.max_path_bytes]) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return try allocator.dupe(u8, targetPathToVersion(buffer[0..target_len]));
}
fn targetPathToVersion(target_path: []const u8) []const u8 {
    return std.fs.path.basename(std.fs.path.dirname(std.fs.path.dirname(target_path).?).?);
}

fn readMasterDir(buffer: *[std.fs.max_path_bytes]u8, install_dir: *Io.Dir) !?[]const u8 {
    if (builtin.os.tag == .windows) {
        var file = install_dir.openFile(g_io, "master", .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close(g_io);
        var buf: [1]u8 = undefined;
        var fr = file.reader(g_io, &buf);
        const data = try fr.interface.allocRemaining(g_gpa, .limited(std.fs.max_path_bytes));
        if (data.len > buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..data.len], data);
        return buffer[0..data.len];
    }
    const len = install_dir.readLink(g_io, "master", buffer) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    return buffer[0..len];
}

fn getDefaultCompiler(allocator: Allocator) !?[]const u8 {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const slice_path = (try readDefaultCompiler(allocator, &buffer)) orelse return null;
    const path_to_return = try allocator.alloc(u8, slice_path.len);
    @memcpy(path_to_return, slice_path);
    return path_to_return;
}

fn getMasterDir(allocator: Allocator, install_dir: *Io.Dir) !?[]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const slice_path = (try readMasterDir(&buffer, install_dir)) orelse return null;
    const path_to_return = try allocator.alloc(u8, slice_path.len);
    @memcpy(path_to_return, slice_path);
    return path_to_return;
}

fn printDefaultCompiler(allocator: Allocator) !void {
    const default_compiler_opt = try getDefaultCompiler(allocator);
    defer if (default_compiler_opt) |default_compiler| allocator.free(default_compiler);
    var buf: [256]u8 = undefined;
    var stdout_file = Io.File.stdout();
    var w = stdout_file.writerStreaming(g_io, &buf);
    const stdout = &w.interface;
    if (default_compiler_opt) |default_compiler| {
        try stdout.print("{s}\n", .{default_compiler});
    } else {
        try stdout.writeAll("<no-default>\n");
    }
    try stdout.flush();
}

const ExistVerify = enum { existence_verified, verify_existence };

fn setDefaultCompiler(allocator: Allocator, compiler_dir: []const u8, exist_verify: ExistVerify) !void {
    switch (exist_verify) {
        .existence_verified => {},
        .verify_existence => {
            var dir = Io.Dir.openDirAbsolute(g_io, compiler_dir, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    std.log.err("compiler '{s}' is not installed", .{std.fs.path.basename(compiler_dir)});
                    return error.AlreadyReported;
                },
                else => |e| return e,
            };
            dir.close(g_io);
        },
    }

    const path_link = try makeZigPathLinkString(allocator);
    defer allocator.free(path_link);

    const link_target = try std.fs.path.join(
        allocator,
        &[_][]const u8{ compiler_dir, "files", comptime "zig" ++ builtin.target.exeFileExt() },
    );
    defer allocator.free(link_target);
    if (builtin.os.tag == .windows) {
        try createExeLink(link_target, path_link);
    } else {
        _ = try loggyUpdateSymlink(link_target, path_link, .{});
    }

    try verifyPathLink(allocator, path_link);
}

/// Verify that path_link will work.  It verifies that `path_link` is
/// in PATH and there is no zig executable in an earlier directory in PATH.
fn verifyPathLink(allocator: Allocator, path_link: []const u8) !void {
    const path_link_dir = std.fs.path.dirname(path_link) orelse {
        std.log.err("invalid '--path-link' '{s}', it must be a file (not the root directory)", .{path_link});
        return error.AlreadyReported;
    };

    const path_link_dir_id = blk: {
        var dir = Io.Dir.openDirAbsolute(g_io, path_link_dir, .{}) catch |err| {
            std.log.err("unable to open the path-link directory '{s}': {s}", .{ path_link_dir, @errorName(err) });
            return error.AlreadyReported;
        };
        defer dir.close(g_io);
        break :blk try FileId.initFromDir(g_io, dir, path_link);
    };

    if (builtin.os.tag == .windows) {
        const path_env = g_env.get("PATH") orelse return;

        const pathext_env = g_env.get("PATHEXT") orelse "";

        var path_it = std.mem.tokenizeScalar(u8, path_env, ';');
        while (path_it.next()) |path| {
            switch (try compareDir(path_link_dir_id, path)) {
                .missing => continue,
                // can't be the same directory because we were able to open and get
                // the file id for path_link_dir_id
                .access_denied => {},
                .match => return,
                .mismatch => {},
            }
            {
                const exe = try std.fs.path.join(allocator, &.{ path, "zig" });
                defer allocator.free(exe);
                try enforceNoZig(path_link, exe);
            }

            var ext_it = std.mem.tokenizeScalar(u8, pathext_env, ';');
            while (ext_it.next()) |ext| {
                if (ext.len == 0) continue;
                const basename = try std.mem.concat(allocator, u8, &.{ "zig", ext });
                defer allocator.free(basename);

                const exe = try std.fs.path.join(allocator, &.{ path, basename });
                defer allocator.free(exe);

                try enforceNoZig(path_link, exe);
            }
        }
    } else {
        var path_it = std.mem.tokenizeScalar(u8, g_env.get("PATH") orelse "", ':');
        while (path_it.next()) |path| {
            switch (try compareDir(path_link_dir_id, path)) {
                .missing => continue,
                // can't be the same directory because we were able to open and get
                // the file id for path_link_dir_id
                .access_denied => {},
                .match => return,
                .mismatch => {},
            }
            const exe = try std.fs.path.join(allocator, &.{ path, "zig" });
            defer allocator.free(exe);
            try enforceNoZig(path_link, exe);
        }
    }

    std.log.err("the path link '{s}' is not in PATH", .{path_link});
    return error.AlreadyReported;
}

fn compareDir(dir_id: FileId, other_dir: []const u8) !enum { missing, access_denied, match, mismatch } {
    var dir = Io.Dir.cwd().openDir(g_io, other_dir, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.BadPathName => return .missing,
        error.AccessDenied => return .access_denied,
        else => |e| return e,
    };
    defer dir.close(g_io);
    return if (dir_id.eql(try FileId.initFromDir(g_io, dir, other_dir))) .match else .mismatch;
}

fn enforceNoZig(path_link: []const u8, exe: []const u8) !void {
    var file = Io.Dir.cwd().openFile(g_io, exe, .{}) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => return,
        error.AccessDenied => return, // if there is a Zig it must not be accessible
        else => |e| return e,
    };
    defer file.close(g_io);

    // todo: on posix systems ignore the file if it is not executable
    std.log.err("zig compiler '{s}' is higher priority in PATH than the path-link '{s}'", .{ exe, path_link });
}

/// Identity of a directory for PATH comparison. On Windows this is the
/// volume serial + file index (GetFileInformationByHandle); on POSIX the
/// new std exposes the inode only (no device id) — same-filesystem
/// assumption, which holds for the PATH dirs that matter here.
const FileId = struct {
    dev: if (builtin.os.tag == .windows) u32 else u64,
    ino: u64,

    pub fn initFromDir(io: Io, dir: Io.Dir, name_for_error: []const u8) !FileId {
        if (builtin.os.tag == .windows) {
            var info: win32.BY_HANDLE_FILE_INFORMATION = undefined;
            if (0 == win32.GetFileInformationByHandle(dir.handle, &info)) {
                std.log.err(
                    "GetFileInformationByHandle on '{s}' failed, error={}",
                    .{ name_for_error, @intFromEnum(std.os.windows.kernel32.GetLastError()) },
                );
                return error.AlreadyReported;
            }
            return FileId{
                .dev = info.dwVolumeSerialNumber,
                .ino = (@as(u64, @intCast(info.nFileIndexHigh)) << 32) | @as(u64, @intCast(info.nFileIndexLow)),
            };
        }
        const st = try dir.stat(io);
        return FileId{
            .dev = 0,
            .ino = @intCast(st.inode),
        };
    }

    pub fn eql(self: FileId, other: FileId) bool {
        return self.dev == other.dev and self.ino == other.ino;
    }
};

const win32 = struct {
    pub const BOOL = i32;
    pub const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };
    pub const BY_HANDLE_FILE_INFORMATION = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        dwVolumeSerialNumber: u32,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
        nNumberOfLinks: u32,
        nFileIndexHigh: u32,
        nFileIndexLow: u32,
    };
    pub extern "kernel32" fn GetFileInformationByHandle(
        hFile: ?@import("std").os.windows.HANDLE,
        lpFileInformation: ?*BY_HANDLE_FILE_INFORMATION,
    ) callconv(.c) BOOL;
};

const win32exelink = struct {
    const content = @embedFile("win32exelink");
    const exe_offset: usize = if (builtin.os.tag != .windows) 0 else blk: {
        @setEvalBranchQuota(content.len * 2);
        const marker = "!!!THIS MARKS THE zig_exe_string MEMORY!!#";
        const offset = std.mem.indexOf(u8, content, marker) orelse {
            @compileError("win32exelink is missing the marker: " ++ marker);
        };
        if (std.mem.indexOf(u8, content[offset + 1 ..], marker) != null) {
            @compileError("win32exelink contains multiple markers (not implemented)");
        }
        break :blk offset + marker.len;
    };
};
fn createExeLink(link_target: []const u8, path_link: []const u8) !void {
    if (path_link.len > std.fs.max_path_bytes) {
        std.debug.print("Error: path_link (size {}) is too large (max {})\n", .{ path_link.len, std.fs.max_path_bytes });
        return error.AlreadyReported;
    }
    const file = Io.Dir.cwd().createFile(g_io, path_link, .{}) catch |err| switch (err) {
        error.IsDir => {
            std.debug.print(
                "unable to create the exe link, the path '{s}' is a directory\n",
                .{path_link},
            );
            std.process.exit(1);
        },
        else => |e| return e,
    };
    defer file.close(g_io);
    var fw = file.writerStreaming(g_io, &.{});
    try fw.interface.writeAll(win32exelink.content[0..win32exelink.exe_offset]);
    try fw.interface.writeAll(link_target);
    try fw.interface.writeAll(win32exelink.content[win32exelink.exe_offset + link_target.len ..]);
    try fw.interface.flush();
}

const Release = struct {
    major: usize,
    minor: usize,
    patch: usize,
    pub fn order(a: Release, b: Release) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

// The Zig release where the OS-ARCH in the url was swapped to ARCH-OS
const arch_os_swap_release: Release = .{ .major = 0, .minor = 14, .patch = 1 };

fn BoundedArray(comptime T: type, comptime max: usize) type {
    // ccached: BoundedArray was removed from the standard library; this
    // shim covers the small subset zigup uses (buffer, len, slice, init).
    return struct {
        const Self = @This();
        buffer: [max]T = undefined,
        len: usize = 0,
        pub fn init(l: usize) error{Overflow}!Self {
            if (l > max) return error.Overflow;
            return .{ .len = l };
        }
        pub fn slice(self: *Self) []T {
            return self.buffer[0..self.len];
        }
        pub fn sliceConst(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }
    };
}

const SemanticVersion = struct {
    const max_pre = 50;
    const max_build = 50;
    const max_string = 50 + max_pre + max_build;

    major: usize,
    minor: usize,
    patch: usize,
    pre: ?BoundedArray(u8, max_pre),
    build: ?BoundedArray(u8, max_build),

    pub fn array(self: *const SemanticVersion) BoundedArray(u8, max_string) {
        var result: BoundedArray(u8, max_string) = undefined;
        const roundtrip = std.fmt.bufPrint(result.buffer[0..], "{f}", .{self}) catch unreachable;
        result.len = roundtrip.len;
        return result;
    }

    pub fn parse(s: []const u8) ?SemanticVersion {
        const parsed = std.SemanticVersion.parse(s) catch |e| switch (e) {
            error.Overflow, error.InvalidVersion => return null,
        };
        std.debug.assert(s.len <= max_string);

        var result: SemanticVersion = .{
            .major = parsed.major,
            .minor = parsed.minor,
            .patch = parsed.patch,
            .pre = if (parsed.pre) |pre| BoundedArray(u8, max_pre).init(pre.len) catch |e| switch (e) {
                error.Overflow => std.debug.panic("semantic version pre '{s}' is too long (max is {})", .{ pre, max_pre }),
            } else null,
            .build = if (parsed.build) |build| BoundedArray(u8, max_build).init(build.len) catch |e| switch (e) {
                error.Overflow => std.debug.panic("semantic version build '{s}' is too long (max is {})", .{ build, max_build }),
            } else null,
        };
        if (parsed.pre) |pre| @memcpy(result.pre.?.slice(), pre);
        if (parsed.build) |build| @memcpy(result.build.?.slice(), build);

        {
            // sanity check, ensure format gives us the same string back we just parsed
            const roundtrip = result.array();
            if (!std.mem.eql(u8, roundtrip.sliceConst(), s)) std.debug.panic(
                "codebug parse/format version mismatch:\nparsed: '{s}'\nformat: '{s}'\n",
                .{ s, roundtrip.sliceConst() },
            );
        }

        return result;
    }
    pub fn ref(self: *const SemanticVersion) std.SemanticVersion {
        return .{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .pre = if (self.pre) |*pre| pre.sliceConst() else null,
            .build = if (self.build) |*build| build.sliceConst() else null,
        };
    }
    pub fn format(
        self: SemanticVersion,
        writer: *Io.Writer,
    ) !void {
        try self.ref().format(writer);
    }
};

fn getDefaultUrl(allocator: Allocator, compiler_version: []const u8) ![]const u8 {
    const sv = SemanticVersion.parse(compiler_version) orelse errExit(
        "invalid zig version '{s}', unable to create a download URL for it",
        .{compiler_version},
    );
    if (sv.pre != null or sv.build != null) return try std.fmt.allocPrint(
        allocator,
        "https://ziglang.org/builds/zig-" ++ arch_os ++ "-{0s}." ++ archive_ext,
        .{compiler_version},
    );
    const release: Release = .{ .major = sv.major, .minor = sv.minor, .patch = sv.patch };
    return try std.fmt.allocPrint(
        allocator,
        "https://ziglang.org/download/{s}/zig-{1s}-{0s}." ++ archive_ext,
        .{
            compiler_version,
            switch (release.order(arch_os_swap_release)) {
                .lt => os_arch,
                .gt, .eq => arch_os,
            },
        },
    );
}

fn installCompiler(allocator: Allocator, compiler_dir: []const u8, url: []const u8) !void {
    if (try existsAbsolute(compiler_dir)) {
        loginfo("compiler '{s}' already installed", .{compiler_dir});
        return;
    }

    const installing_dir = try std.mem.concat(allocator, u8, &[_][]const u8{ compiler_dir, ".installing" });
    defer allocator.free(installing_dir);
    try loggyDeleteTreeAbsolute(installing_dir);
    try loggyMakePath(installing_dir);

    const archive_basename = std.fs.path.basename(url);
    var archive_root_dir: []const u8 = undefined;

    // download and extract archive
    {
        const archive_absolute = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_basename });
        defer allocator.free(archive_absolute);
        loginfo("downloading '{s}' to '{s}'", .{ url, archive_absolute });

        switch (blk: {
            const file = try Io.Dir.createFileAbsolute(g_io, archive_absolute, .{});
            // note: important to close the file before we handle errors below
            //       since it will delete the parent directory of this file
            defer file.close(g_io);
            var fw = file.writer(g_io, &.{});
            break :blk download(allocator, url, &fw.interface);
        }) {
            .ok => {},
            .err => |err| {
                std.log.err("could not download '{s}': {s}", .{ url, err });
                // this removes the installing dir if the http request fails so we dont have random directories
                try loggyDeleteTreeAbsolute(installing_dir);
                return error.AlreadyReported;
            },
        }

        if (std.mem.endsWith(u8, archive_basename, ".tar.xz")) {
            archive_root_dir = archive_basename[0 .. archive_basename.len - ".tar.xz".len];
            _ = try run(allocator, &[_][]const u8{ "tar", "xf", archive_absolute, "-C", installing_dir });
        } else {
            var recognized = false;
            if (builtin.os.tag == .windows) {
                if (std.mem.endsWith(u8, archive_basename, ".zip")) {
                    recognized = true;
                    archive_root_dir = archive_basename[0 .. archive_basename.len - ".zip".len];

                    var installing_dir_opened = try Io.Dir.openDirAbsolute(g_io, installing_dir, .{});
                    defer installing_dir_opened.close(g_io);
                    loginfo("extracting archive to \"{s}\"", .{installing_dir});
                    const start = Io.Timestamp.now(g_io, .awake);
                    var archive_file = try Io.Dir.openFileAbsolute(g_io, archive_absolute, .{});
                    defer archive_file.close(g_io);
                    var archive_buf: [64 * 1024]u8 = undefined;
                    var archive_reader = archive_file.readerStreaming(g_io, &archive_buf);
                    try std.zip.extract(installing_dir_opened, &archive_reader, .{});
                    const dur = Io.Timestamp.durationTo(start, Io.Timestamp.now(g_io, .awake));
                    loginfo("extracted archive in {d:.2} s", .{@as(f32, @floatFromInt(dur.nanoseconds)) / @as(f32, @floatFromInt(std.time.ns_per_s))});
                }
            }

            if (!recognized) {
                std.log.err("unknown archive extension '{s}'", .{archive_basename});
                return error.UnknownArchiveExtension;
            }
        }
        try loggyDeleteTreeAbsolute(archive_absolute);
    }

    {
        const extracted_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, archive_root_dir });
        defer allocator.free(extracted_dir);
        const normalized_dir = try std.fs.path.join(allocator, &[_][]const u8{ installing_dir, "files" });
        defer allocator.free(normalized_dir);
        try loggyRenameAbsolute(extracted_dir, normalized_dir);
    }

    // TODO: write date information (so users can sort compilers by date)

    // finish installation by renaming the install dir
    try loggyRenameAbsolute(installing_dir, compiler_dir);
}

pub fn run(allocator: Allocator, argv: []const []const u8) !process.Child.Term {
    try logRun(allocator, argv);
    var child = try process.spawn(g_io, .{
        .argv = argv,
        .environ_map = null,
    });
    return child.wait(g_io);
}

fn logRun(allocator: Allocator, argv: []const []const u8) !void {
    var buffer = try allocator.alloc(u8, getCommandStringLength(argv));
    defer allocator.free(buffer);

    var prefix = false;
    var offset: usize = 0;
    for (argv) |arg| {
        if (prefix) {
            buffer[offset] = ' ';
            offset += 1;
        } else {
            prefix = true;
        }
        @memcpy(buffer[offset .. offset + arg.len], arg);
        offset += arg.len;
    }
    std.debug.assert(offset == buffer.len);
    loginfo("[RUN] {s}", .{buffer});
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

pub fn getCommandStringLength(argv: []const []const u8) usize {
    var len: usize = 0;
    var prefix_length: u8 = 0;
    for (argv) |arg| {
        len += prefix_length + arg.len;
        prefix_length = 1;
    }
    return len;
}

pub fn getKeepReason(master_points_to_opt: ?[]const u8, default_compiler_opt: ?[]const u8, name: []const u8) ?[]const u8 {
    if (default_compiler_opt) |default_comp| {
        if (mem.eql(u8, default_comp, name)) {
            return "is default compiler";
        }
    }
    if (master_points_to_opt) |master_points_to| {
        if (mem.eql(u8, master_points_to, name)) {
            return "it is master";
        }
    }
    return null;
}
