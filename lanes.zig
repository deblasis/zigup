// lanes.zig — zigup lane support (2026-08-30, ccached project).
//
// A "lane" is a named compiler toolchain directory containing a `zig`
// executable (optionally `files/zig` for zigup-fetched toolchains). Lanes let
// one machine host several compiler lines — e.g. stable (official 0.16),
// ccached (0.16 + central cache), vigz (the fork) — with per-folder and
// per-session selection, while keeping stock zigup behavior and conventions.
//
// Resolution order for the implicit `zig` shim:
//   1. ZIGUP_LANE environment variable (session pin)
//   2. `.ziglane` file in the current directory or an ancestor (project pin;
//      this file is also the public "safe to use the fork here" marker)
//   3. the default lane (`zigup lane default <name>`)
//
// Shims are copies of the zigup executable named `zig` / `<lane>`; dispatch is
// by argv0 basename, the same convention zig itself uses.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Lane = struct {
    name: []const u8,
    dir: []const u8,
};

// ---------------------------------------------------------------- settings

fn lanesFilePath(allocator: Allocator) !?[]const u8 {
    const appdata: []const u8 = std.fs.getAppDataDir(allocator, "zigup") catch |err| switch (err) {
        error.OutOfMemory => |e| oom(e),
        error.AppDataDirUnavailable => return null,
    };
    defer allocator.free(appdata);
    const p: []const u8 = try std.fs.path.join(allocator, &.{ appdata, "lanes" });
    return p;
}

fn defaultLaneFilePath(allocator: Allocator) !?[]const u8 {
    const appdata: []const u8 = std.fs.getAppDataDir(allocator, "zigup") catch |err| switch (err) {
        error.OutOfMemory => |e| oom(e),
        error.AppDataDirUnavailable => return null,
    };
    defer allocator.free(appdata);
    const p: []const u8 = try std.fs.path.join(allocator, &.{ appdata, "lane-default" });
    return p;
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn readLanes(allocator: Allocator) ![]Lane {
    var list: []Lane = &.{};
    const path = (try lanesFilePath(allocator)) orelse return list;
    defer allocator.free(path);
    const content = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return list,
        else => |e| {
            std.log.err("open lanes file '{s}' failed with {s}", .{ path, @errorName(e) });
            return e;
        },
    };
    defer content.close();
    const data = try content.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " ");
        const dir = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (name.len == 0 or dir.len == 0) continue;
        list = try appendLane(allocator, list, .{
            .name = try allocator.dupe(u8, name),
            .dir = try allocator.dupe(u8, dir),
        });
    }
    return list;
}

fn appendLane(allocator: Allocator, list: []Lane, lane: Lane) ![]Lane {
    const grown = try allocator.alloc(Lane, list.len + 1);
    @memcpy(grown[0..list.len], list);
    grown[list.len] = lane;
    return grown;
}

fn saveLanes(allocator: Allocator, lanes: []const Lane) !void {
    const path = (try lanesFilePath(allocator)) orelse {
        std.log.err("cannot save lanes: no settings directory available", .{});
        return error.NoSettingsDir;
    };
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var w = file.writer(&.{});
    for (lanes) |lane| {
        try w.interface.print("{s}={s}\n", .{ lane.name, lane.dir });
    }
    try w.interface.flush();
}

pub fn findLane(lanes: []const Lane, name: []const u8) ?Lane {
    for (lanes) |lane| {
        if (std.mem.eql(u8, lane.name, name)) return lane;
    }
    return null;
}

// ------------------------------------------------------------- default lane

pub fn getDefaultLane(allocator: Allocator) !?[]const u8 {
    const path = (try defaultLaneFilePath(allocator)) orelse return null;
    defer allocator.free(path);
    const content = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer content.close();
    const data = try content.readToEndAlloc(allocator, 4096);
    defer allocator.free(data);
    const trimmed = std.mem.trim(u8, data, " \r\n\t");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn setDefaultLane(allocator: Allocator, name: []const u8) !void {
    const path = (try defaultLaneFilePath(allocator)) orelse {
        std.log.err("cannot save default lane: no settings directory available", .{});
        return error.NoSettingsDir;
    };
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var w = file.writer(&.{});
    try w.interface.print("{s}\n", .{name});
    try w.interface.flush();
}

// ---------------------------------------------------------------- resolution

fn findDotZiglane(allocator: Allocator) !?[]const u8 {
    const cwd_alloc = std.process.getCwdAlloc(allocator) catch return null;
    var dir: []const u8 = cwd_alloc;
    var depth: usize = 0;
    while (depth < 24) : (depth += 1) {
        const candidate = std.fs.path.join(allocator, &.{ dir, ".ziglane" }) catch |e| oom(e);
        defer allocator.free(candidate);
        if (std.fs.cwd().openFile(candidate, .{})) |file| {
            defer file.close();
            const data = file.readToEndAlloc(allocator, 4096) catch return null;
            defer allocator.free(data);
            const trimmed = std.mem.trim(u8, data, " \r\n\t");
            if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
            return null;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
    return null;
}

/// Resolve the lane name in force for the current context.
pub fn resolveLane(allocator: Allocator) !?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZIGUP_LANE")) |v| {
        const trimmed = std.mem.trim(u8, v, " \r\n\t");
        if (trimmed.len > 0) return trimmed;
        return null;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        error.InvalidWtf8 => return null,
        else => |e| return e,
    }
    if (try findDotZiglane(allocator)) |from_file| return from_file;
    return try getDefaultLane(allocator);
}

// -------------------------------------------------------------------- exec

fn zigExePathIn(allocator: Allocator, dir: []const u8) ![]const u8 {
    const exe_ext = builtin_target_exe_ext();
    const direct = try std.fmt.allocPrint(allocator, "{s}/zig{s}", .{ dir, exe_ext });
    if (std.fs.cwd().access(direct, .{})) |_| return direct else |_| {}
    const files = try std.fmt.allocPrint(allocator, "{s}/files/zig{s}", .{ dir, exe_ext });
    if (std.fs.cwd().access(files, .{})) |_| return files else |_| {}
    return direct;
}

fn builtin_target_exe_ext() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => ".exe",
        else => "",
    };
}

pub fn execLane(allocator: Allocator, lanes: []const Lane, name: []const u8, passthrough: []const []const u8) !u8 {
    const lane = findLane(lanes, name) orelse {
        std.log.err("lane '{s}' is not configured; add it with: zigup lane set {s} <toolchain-dir>", .{ name, name });
        return 0xff;
    };
    const zig_path = try zigExePathIn(allocator, lane.dir);
    if (std.fs.cwd().access(zig_path, .{})) |_| {} else |_| {
        std.log.err("lane '{s}' points at '{s}' but no zig executable was found there", .{ name, lane.dir });
        return 0xff;
    }
    const argv = try allocator.alloc([]const u8, 1 + passthrough.len);
    argv[0] = zig_path;
    for (passthrough, 0..) |a, i| argv[1 + i] = a;
    var proc = std.process.Child.init(argv, allocator);
    const term = try proc.spawnAndWait();
    switch (term) {
        .Exited => |code| return code,
        else => |result| {
            std.log.err("lane '{s}' compiler exited with {}", .{ name, result });
            return 0xff;
        },
    }
}

// ------------------------------------------------------------------ shim

fn basenameNoExe(path: []const u8) []const u8 {
    var base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".exe")) base = base[0 .. base.len - 4];
    return base;
}

/// If this process was launched through a lane shim (argv0 `zig` or a lane
/// name), dispatch to the resolved lane's compiler and return the exit code.
/// Returns null when running as plain `zigup` (normal CLI continues).
pub fn shimDispatch(allocator: Allocator) !?u8 {
    const args = try std.process.argsAlloc(allocator);
    if (args.len == 0) return null;
    const base = basenameNoExe(args[0]);
    if (std.mem.eql(u8, base, "zigup")) return null;

    const lanes = try readLanes(allocator);

    if (!std.mem.eql(u8, base, "zig")) {
        // A lane-named shim: exact lane name (vigz) or zig_-prefixed (zig_ccached).
        if (findLane(lanes, base) != null) return try execLaneWithArgs(allocator, lanes, base, args[1..]);
        if (std.mem.startsWith(u8, base, "zig_")) {
            const lane_name = base[4..];
            if (findLane(lanes, lane_name) != null) return try execLaneWithArgs(allocator, lanes, lane_name, args[1..]);
        }
        return null; // unknown name: not ours
    }

    // `zig` shim: resolve per session > project > default.
    const lane_name = (try resolveLane(allocator)) orelse {
        std.log.err("zigup: no lane configured for 'zig'; run: zigup lane set <name> <dir> && zigup lane default <name>", .{});
        return 0xff;
    };
    return try execLaneWithArgs(allocator, lanes, lane_name, args[1..]);
}

fn execLaneWithArgs(allocator: Allocator, lanes: []const Lane, name: []const u8, args: []const [:0]u8) !u8 {
    const passthrough = try allocator.alloc([]const u8, args.len);
    for (args, 0..) |a, i| passthrough[i] = a;
    return try execLane(allocator, lanes, name, passthrough);
}

// ------------------------------------------------------------ subcommands

pub fn laneSet(allocator: Allocator, name: []const u8, dir_in: []const u8) !u8 {
    const dir = if (std.fs.path.isAbsolute(dir_in)) dir_in else try toAbs(allocator, dir_in);
    const probe = try zigExePathIn(allocator, dir);
    if (std.fs.cwd().access(probe, .{})) |_| {} else |_| {
        std.log.err("'{s}' does not contain a zig executable (looked for '{s}')", .{ dir, probe });
        return 1;
    }
    const lanes = try readLanes(allocator);
    var replaced = false;
    var new_lanes: []Lane = &.{};
    for (lanes) |lane| {
        if (std.mem.eql(u8, lane.name, name)) {
            new_lanes = try appendLane(allocator, new_lanes, .{ .name = lane.name, .dir = dir });
            replaced = true;
        } else new_lanes = try appendLane(allocator, new_lanes, lane);
    }
    if (!replaced) new_lanes = try appendLane(allocator, new_lanes, .{ .name = name, .dir = dir });
    try saveLanes(allocator, new_lanes);
    std.debug.print("lane '{s}' -> {s}\n", .{ name, dir });
    return 0;
}

pub fn laneRemove(allocator: Allocator, name: []const u8) !u8 {
    const lanes = try readLanes(allocator);
    var new_lanes: []Lane = &.{};
    var removed = false;
    for (lanes) |lane| {
        if (std.mem.eql(u8, lane.name, name)) {
            removed = true;
        } else new_lanes = try appendLane(allocator, new_lanes, lane);
    }
    if (!removed) {
        std.log.err("lane '{s}' is not configured", .{name});
        return 1;
    }
    try saveLanes(allocator, new_lanes);
    std.debug.print("lane '{s}' removed\n", .{name});
    return 0;
}

pub fn laneList(allocator: Allocator) !u8 {
    const lanes = try readLanes(allocator);
    const def = try getDefaultLane(allocator);
    for (lanes) |lane| {
        const marker = if (def != null and std.mem.eql(u8, def.?, lane.name)) " (default)" else "";
        std.debug.print("{s}{s}\t{s}\n", .{ lane.name, marker, lane.dir });
    }
    if (def == null and lanes.len > 0) std.debug.print("(no default lane set)\n", .{});
    return 0;
}

pub fn laneDefault(allocator: Allocator, maybe_name: ?[]const u8) !u8 {
    if (maybe_name) |name| {
        const lanes = try readLanes(allocator);
        if (findLane(lanes, name) == null) {
            std.log.err("lane '{s}' is not configured", .{name});
            return 1;
        }
        try setDefaultLane(allocator, name);
        std.debug.print("default lane: {s}\n", .{name});
        return 0;
    }
    if (try getDefaultLane(allocator)) |d| {
        std.debug.print("{s}\n", .{d});
        return 0;
    }
    std.log.err("no default lane set", .{});
    return 1;
}

// ---------------------------------------------------------------- shims

/// Copy the zigup executable next to itself under `name` (and `name.exe` on
/// Windows), creating a lane dispatch shim.
pub fn shimInstall(allocator: Allocator, names: []const []const u8) !u8 {
    const self = try std.fs.selfExePathAlloc(allocator);
    const self_dir = try std.fs.selfExeDirPathAlloc(allocator);
    const exe_ext = builtin_target_exe_ext();
    for (names) |raw| {
        const name = basenameNoExe(raw);
        if (std.mem.eql(u8, name, "zigup")) continue;
        const dest = try std.fs.path.join(allocator, &.{ self_dir, try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, exe_ext }) });
        try std.fs.cwd().copyFile(self, std.fs.cwd(), dest, .{});
        std.debug.print("shim: {s}\n", .{dest});
    }
    return 0;
}

fn toAbs(allocator: Allocator, path: []const u8) ![]u8 {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}
