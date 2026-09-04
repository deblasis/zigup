//! zlane — the zig lane resolver (2026-09-04; lineage: the zigup `lanes`
//! fork, reborn standalone against zig 0.16-final's Io std).
//!
//! One machine, several compiler lines (stable / ccached / vigz / ...), one
//! `zig` command that always means the right one:
//!
//!   `zig` resolution order:
//!     1. $ZIGUP_LANE (session pin; the value `path` skips lanes entirely)
//!     2. .ziglane file in the cwd or an ancestor (project pin — also the
//!        public "safe to use the fork here" marker)
//!     3. the default lane (`zlane default <name>`)
//!     4. `zig` found on PATH (excluding this shim's own directory)
//!
//!   Fallback discipline: only a source expressing NO intent falls back to
//!   PATH (nothing configured, or a broken default lane — a machine
//!   preference must not brick `zig`). An EXPLICIT pin ($ZIGUP_LANE or a
//!   .ziglane naming a missing/broken lane) is a HARD ERROR: silently
//!   substituting a different compiler era is exactly the failure class
//!   lanes exist to prevent.
//!
//!   Lane-named shims (`zig_ccached`, `vigz`, ...) always run exactly that
//!   lane; a broken one is a hard error.
//!
//! Configuration (same files the zigup fork used, so existing setups carry
//! over): <settings>/zigup/lanes holds `name=dir` lines, and
//! <settings>/zigup/lane-default holds the default lane name, where
//! <settings> is %LOCALAPPDATA% on Windows and $XDG_CONFIG_HOME or
//! ~/.config elsewhere.
//!
//! Shims are copies of this executable named `zig` / `zig_<lane>` / `<lane>`
//! (`zlane shim` installs them next to the running binary); dispatch is by
//! argv[0] basename, the convention zig itself uses.
//!
//! Management CLI (run as `zlane`):
//!   zlane set <name> <dir>    register a lane (validates the zig executable)
//!   zlane remove <name>
//!   zlane list
//!   zlane default [name]
//!   zlane shim [names...]     install shims next to this binary
//!   zlane which               what would `zig` resolve to, and why
//!   zlane path                just the resolved zig path (scriptable)

const std = @import("std");
const Io = std.Io;
const process = std.process;

const Lane = struct { name: []const u8, dir: []const u8 };
const Source = enum { env, project, default };
const Resolved = struct { name: []const u8, source: Source };

// Stashed by main() for the helpers (single-threaded CLI; 0.16-final has no
// selfExe API, so argv[0] is the self-reference).
var init_environ: *const process.Environ.Map = undefined;
var init_args: process.Args = undefined;
var init_argv0: []const u8 = "";

pub fn main(init: process.Init) !u8 {
    // Arena over page memory: a short-lived CLI that never frees
    // (DebugAllocator leak reports at exit are noise here).
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const gpa = arena.allocator();
    const io = init.io;
    init_environ = init.environ_map;
    init_args = init.minimal.args;

    var it = try process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    const argv0 = it.next() orelse return fatal("no argv[0]", .{});
    init_argv0 = argv0;
    var args = std.ArrayList([]const u8).empty;
    while (it.next()) |a| try args.append(gpa, a);

    const base = basenameNoExe(argv0);
    if (std.mem.eql(u8, base, "zlane")) return try cli(io, gpa, args.items);
    return try shimDispatch(io, gpa, argv0, base, args.items);
}

fn fatal(comptime fmt: []const u8, fmt_args: anytype) u8 {
    std.debug.print("zlane: " ++ fmt ++ "\n", fmt_args);
    return 0xff;
}

// ------------------------------------------------------------------ helpers

fn basenameNoExe(path: []const u8) []const u8 {
    var base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".exe")) base = base[0 .. base.len - 4];
    return base;
}

fn exeExt() []const u8 {
    return switch (@import("builtin").os.tag) {
        .windows => ".exe",
        else => "",
    };
}

const windows_host = @import("builtin").os.tag == .windows;

fn samePath(a: []const u8, b: []const u8) bool {
    if (windows_host) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

fn trimTrailingSep(p: []const u8) []const u8 {
    var path = p;
    while (path.len > 1 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\')) path = path[0 .. path.len - 1];
    return path;
}

fn dirnameOf(p: []const u8) ?[]const u8 {
    const d = std.fs.path.dirname(p) orelse return null;
    if (d.len == 0) return null;
    return d;
}

/// Absolute-ish directory of this executable, derived from argv[0]. Good
/// enough for shim-install and PATH self-exclusion (0.16-final std has no
/// selfExe API); the PATH fallback also carries a loop guard for the cases
/// argv[0] lies.
fn selfDir(io: Io, gpa: std.mem.Allocator, argv0: []const u8) ?[]const u8 {
    // NOTE: fs.path.resolve can return a RELATIVE path when fed relative
    // inputs (resolve(".", "./x") -> "x") — anchor on the cwd so the
    // result is absolute, or PATH self-exclusion silently fails.
    const cwd = process.currentPathAlloc(io, gpa) catch return null;
    const abs = if (std.fs.path.isAbsolute(argv0))
        argv0
    else
        std.fs.path.resolve(gpa, &.{ cwd, argv0 }) catch return null;
    return trimTrailingSep(dirnameOf(abs) orelse return null);
}

/// argv0 made absolute (readFileSmall via the cwd handle chokes on
/// relative "./x" forms on some hosts).
fn selfPathAbs(io: Io, gpa: std.mem.Allocator, argv0: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(argv0)) return argv0;
    const cwd = process.currentPathAlloc(io, gpa) catch return argv0;
    return std.fs.path.resolve(gpa, &.{ cwd, argv0 }) catch argv0;
}

fn readFileSmall(io: Io, gpa: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    const cwd = Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var buf: [1]u8 = undefined;
    var fr = f.reader(io, &buf);
    return fr.interface.allocRemaining(gpa, .limited(max)) catch null;
}

// ------------------------------------------------------------- settings I/O

fn settingsDir(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map) !?[]const u8 {
    _ = io;
    if (env.get("ZLANE_SETTINGS")) |s| {
        if (s.len > 0) return s;
    }
    if (windows_host) {
        const lad = env.get("LOCALAPPDATA") orelse return null;
        if (lad.len == 0) return null;
        return try std.fs.path.join(gpa, &.{ lad, "zigup" });
    }
    if (@import("builtin").os.tag.isDarwin()) {
        const home = env.get("HOME") orelse return null;
        if (home.len == 0) return null;
        return try std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "zigup" });
    }
    if (env.get("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return try std.fs.path.join(gpa, &.{ x, "zigup" });
    }
    if (env.get("HOME")) |home| {
        if (home.len > 0) return try std.fs.path.join(gpa, &.{ home, ".config", "zigup" });
    }
    return null;
}

fn readLanes(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map) ![]Lane {
    var list: std.ArrayList(Lane) = .empty;
    const dir = (try settingsDir(io, gpa, env)) orelse return list.toOwnedSlice(gpa);
    const path = try std.fs.path.join(gpa, &.{ dir, "lanes" });
    const data = readFileSmall(io, gpa, path, 1 << 20) orelse return list.toOwnedSlice(gpa);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " ");
        const ldir = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (name.len == 0 or ldir.len == 0) continue;
        try list.append(gpa, .{ .name = name, .dir = ldir });
    }
    return list.toOwnedSlice(gpa);
}

fn saveLanes(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map, lanes: []const Lane) !void {
    const dir = (try settingsDir(io, gpa, env)) orelse return error.NoSettingsDir;
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "lanes" });
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    for (lanes) |lane| {
        try w.interface.print("{s}={s}\n", .{ lane.name, lane.dir });
    }
    try w.interface.flush();
}

fn getDefaultLane(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map) !?[]const u8 {
    const dir = (try settingsDir(io, gpa, env)) orelse return null;
    const path = try std.fs.path.join(gpa, &.{ dir, "lane-default" });
    const data = readFileSmall(io, gpa, path, 4096) orelse return null;
    const trimmed = std.mem.trim(u8, data, " \r\n\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn setDefaultLane(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map, name: []const u8) !void {
    const dir = (try settingsDir(io, gpa, env)) orelse return error.NoSettingsDir;
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "lane-default" });
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.print("{s}\n", .{name});
    try w.interface.flush();
}

// ---------------------------------------------------------------- resolution

fn findLane(lanes: []const Lane, name: []const u8) ?Lane {
    for (lanes) |lane| {
        if (std.mem.eql(u8, lane.name, name)) return lane;
    }
    return null;
}

fn findDotZiglane(io: Io, gpa: std.mem.Allocator) ?[]const u8 {
    const cwd_alloc = process.currentPathAlloc(io, gpa) catch return null;
    var dir: []const u8 = trimTrailingSep(cwd_alloc);
    var depth: usize = 0;
    while (depth < 24) : (depth += 1) {
        const candidate = std.fs.path.join(gpa, &.{ dir, ".ziglane" }) catch return null;
        if (readFileSmall(io, gpa, candidate, 4096)) |data| {
            const trimmed = std.mem.trim(u8, data, " \r\n\t");
            if (trimmed.len == 0) return null;
            return trimmed;
        }
        const parent = dirnameOf(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
    return null;
}

fn resolveLane(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map) !?Resolved {
    if (env.get("ZIGUP_LANE")) |v| {
        const trimmed = std.mem.trim(u8, v, " \r\n\t");
        if (trimmed.len > 0) return .{ .name = trimmed, .source = .env };
        return null;
    }
    if (findDotZiglane(io, gpa)) |from_file| return .{ .name = from_file, .source = .project };
    if (try getDefaultLane(io, gpa, env)) |d| return .{ .name = d, .source = .default };
    return null;
}

// ---------------------------------------------------------------------- exec

fn zigExeIn(gpa: std.mem.Allocator, io: Io, lane_dir: []const u8) !?[]const u8 {
    const exe_name = try std.fmt.allocPrint(gpa, "zig{s}", .{exeExt()});
    const direct = try std.fs.path.join(gpa, &.{ lane_dir, exe_name });
    Io.Dir.cwd().access(io, direct, .{}) catch {
        const files = try std.fs.path.join(gpa, &.{ lane_dir, "files", exe_name });
        Io.Dir.cwd().access(io, files, .{}) catch return null;
        return files;
    };
    return direct;
}

fn execZig(io: Io, gpa: std.mem.Allocator, zig_path: []const u8, passthrough: []const []const u8) !u8 {
    const argv = try gpa.alloc([]const u8, 1 + passthrough.len);
    argv[0] = zig_path;
    for (passthrough, 0..) |a, i| argv[1 + i] = a;
    var child = process.spawn(io, .{
        .argv = argv,
        .environ_map = null, // inherit
    }) catch |err| return fatal("failed to spawn '{s}': {t}", .{ zig_path, err });
    const term = child.wait(io) catch |err| return fatal("wait on '{s}' failed: {t}", .{ zig_path, err });
    switch (term) {
        .exited => |code| return code,
        else => |t| return fatal("'{s}' terminated abnormally: {t}", .{ zig_path, t }),
    }
}

fn findZigOnPath(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map, argv0: []const u8) !?[]const u8 {
    const path_var = env.get("PATH") orelse return null;
    const self_dir = selfDir(io, gpa, argv0);
    const exe_name = try std.fmt.allocPrint(gpa, "zig{s}", .{exeExt()});
    const sep: u8 = if (windows_host) ';' else ':';
    var entries = std.mem.splitScalar(u8, path_var, sep);
    while (entries.next()) |entry_raw| {
        const entry = trimTrailingSep(std.mem.trim(u8, entry_raw, " \""));
        if (entry.len == 0) continue;
        if (self_dir) |sd| {
            if (samePath(entry, sd)) continue;
        }
        const candidate = try std.fs.path.join(gpa, &.{ entry, exe_name });
        Io.Dir.cwd().access(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

// Loop guard: if this process was itself reached via a PATH fallback and the
// fallback resolves to us again, bail instead of spawning forever.
const guard_env = "ZLANE_FALLBACK_ACTIVE";

fn execPathFallback(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map, argv0: []const u8, passthrough: []const []const u8) !u8 {
    if (env.get(guard_env) != null) return fatal("PATH fallback loop detected (this shim IS the zig on PATH)", .{});
    const zig_path = (try findZigOnPath(io, gpa, env, argv0)) orelse
        return fatal("no lane resolved and no zig found on PATH", .{});
    const argv = try gpa.alloc([]const u8, 1 + passthrough.len);
    argv[0] = zig_path;
    for (passthrough, 0..) |a, i| argv[1 + i] = a;

    // Set the guard in the child environment.
    var env_copy = process.Environ.Map.init(gpa);
    defer env_copy.deinit();
    for (env.keys(), env.values()) |key, value| {
        try env_copy.put(key, value);
    }
    try env_copy.put(guard_env, "1");

    var child = process.spawn(io, .{
        .argv = argv,
        .environ_map = &env_copy,
    }) catch |err| return fatal("failed to spawn '{s}': {t}", .{ zig_path, err });
    const term = child.wait(io) catch |err| return fatal("wait on '{s}' failed: {t}", .{ zig_path, err });
    switch (term) {
        .exited => |code| return code,
        else => |t| return fatal("'{s}' terminated abnormally: {t}", .{ zig_path, t }),
    }
}

// ------------------------------------------------------------ shim dispatch

fn shimDispatch(io: Io, gpa: std.mem.Allocator, argv0: []const u8, base: []const u8, args: []const []const u8) !u8 {
    const env = init_environ;
    const lanes = try readLanes(io, gpa, env);

    if (!std.mem.eql(u8, base, "zig")) {
        // A lane-named shim: `vigz` or `zig_ccached`. Explicit: never falls
        // back.
        var lane_name = base;
        if (findLane(lanes, lane_name) == null and std.mem.startsWith(u8, base, "zig_")) {
            lane_name = base[4..];
        }
        const lane = findLane(lanes, lane_name) orelse
            return fatal("lane '{s}' is not configured (fix: zlane set {s} <dir>)", .{ lane_name, lane_name });
        const zig_path = (try zigExeIn(gpa, io, lane.dir)) orelse
            return fatal("lane '{s}' has no zig executable in '{s}'", .{ lane_name, lane.dir });
        return try execZig(io, gpa, zig_path, args);
    }

    // The `zig` shim.
    const resolved = (try resolveLane(io, gpa, env)) orelse {
        return try execPathFallback(io, gpa, env, argv0, args);
    };
    if (resolved.source == .env and std.mem.eql(u8, resolved.name, "path")) {
        return try execPathFallback(io, gpa, env, argv0, args);
    }
    const lane = findLane(lanes, resolved.name);
    const zig_path = if (lane) |l| try zigExeIn(gpa, io, l.dir) else null;
    if (zig_path == null) {
        if (resolved.source == .default) {
            std.debug.print("zlane: warning: default lane '{s}' is not usable; falling back to zig on PATH\n", .{resolved.name});
            return try execPathFallback(io, gpa, env, argv0, args);
        }
        return fatal(
            "lane '{s}' (from {s}) is not configured or has no zig executable; refusing to substitute another compiler (fix: zlane set {s} <dir>)",
            .{ resolved.name, switch (resolved.source) {
                .env => "$ZIGUP_LANE",
                .project => ".ziglane",
                .default => "default lane",
            }, resolved.name },
        );
    }
    return try execZig(io, gpa, zig_path.?, args);
}

// ----------------------------------------------------------------- the CLI

fn cli(io: Io, gpa: std.mem.Allocator, args: []const []const u8) !u8 {
    const env = init_environ;
    const cmd = if (args.len > 0) args[0] else "";

    if (std.mem.eql(u8, cmd, "doctor")) {
        return try doctor(io, gpa, env, init_argv0);
    }
    if (std.mem.eql(u8, cmd, "run")) {
        // `zlane run ...` = exactly what the `zig` shim would do.
        return try shimDispatch(io, gpa, init_argv0, "zig", args[1..]);
    }

    if (std.mem.eql(u8, cmd, "list")) {
        const lanes = try readLanes(io, gpa, env);
        const def = try getDefaultLane(io, gpa, env);
        for (lanes) |lane| {
            const marker = if (def != null and std.mem.eql(u8, def.?, lane.name)) " (default)" else "";
            std.debug.print("{s}{s}\t{s}\n", .{ lane.name, marker, lane.dir });
        }
        if (def == null and lanes.len > 0) std.debug.print("(no default lane set)\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "set")) {
        if (args.len < 3) return fatal("usage: zlane set <name> <dir>", .{});
        const name = args[1];
        const dir = args[2];
        if ((try zigExeIn(gpa, io, dir)) == null)
            return fatal("'{s}' contains no zig executable (looked for zig{s} and files/zig{s})", .{ dir, exeExt(), exeExt() });
        const lanes = try readLanes(io, gpa, env);
        var out: std.ArrayList(Lane) = .empty;
        var replaced = false;
        for (lanes) |lane| {
            if (std.mem.eql(u8, lane.name, name)) {
                try out.append(gpa, .{ .name = name, .dir = dir });
                replaced = true;
            } else try out.append(gpa, lane);
        }
        if (!replaced) try out.append(gpa, .{ .name = name, .dir = dir });
        try saveLanes(io, gpa, env, out.items);
        std.debug.print("lane '{s}' -> {s}\n", .{ name, dir });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "remove")) {
        if (args.len < 2) return fatal("usage: zlane remove <name>", .{});
        const lanes = try readLanes(io, gpa, env);
        var out: std.ArrayList(Lane) = .empty;
        var removed = false;
        for (lanes) |lane| {
            if (std.mem.eql(u8, lane.name, args[1])) {
                removed = true;
            } else try out.append(gpa, lane);
        }
        if (!removed) return fatal("lane '{s}' is not configured", .{args[1]});
        try saveLanes(io, gpa, env, out.items);
        std.debug.print("lane '{s}' removed\n", .{args[1]});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "default")) {
        if (args.len >= 2) {
            const lanes = try readLanes(io, gpa, env);
            if (findLane(lanes, args[1]) == null) return fatal("lane '{s}' is not configured", .{args[1]});
            try setDefaultLane(io, gpa, env, args[1]);
            std.debug.print("default lane: {s}\n", .{args[1]});
            return 0;
        }
        if (try getDefaultLane(io, gpa, env)) |d| {
            std.debug.print("{s}\n", .{d});
            return 0;
        }
        return fatal("no default lane set", .{});
    }
    if (std.mem.eql(u8, cmd, "which") or std.mem.eql(u8, cmd, "path")) {
        const scriptable = std.mem.eql(u8, cmd, "path");
        const lanes = try readLanes(io, gpa, env);
        const resolved = (try resolveLane(io, gpa, env)) orelse {
            const p = try findZigOnPath(io, gpa, env, "zig");
            if (p) |zig| {
                if (scriptable) {
                    std.debug.print("{s}\n", .{zig});
                } else std.debug.print("path-fallback (no lane resolved): {s}\n", .{zig});
                return 0;
            }
            return fatal("nothing resolves: no lane and no zig on PATH", .{});
        };
        if (resolved.source == .env and std.mem.eql(u8, resolved.name, "path")) {
            const p = try findZigOnPath(io, gpa, env, "zig");
            if (p) |zig| {
                if (scriptable) {
                    std.debug.print("{s}\n", .{zig});
                } else std.debug.print("$ZIGUP_LANE=path: {s}\n", .{zig});
                return 0;
            }
            return fatal("$ZIGUP_LANE=path but no zig on PATH", .{});
        }
        const lane = findLane(lanes, resolved.name);
        const zig = if (lane) |l| try zigExeIn(gpa, io, l.dir) else null;
        const src = switch (resolved.source) {
            .env => "$ZIGUP_LANE",
            .project => ".ziglane",
            .default => "default lane",
        };
        if (zig) |z| {
            if (scriptable) {
                std.debug.print("{s}\n", .{z});
            } else std.debug.print("{s}: lane '{s}' -> {s}\n", .{ src, resolved.name, z });
        } else {
            std.debug.print("{s}: lane '{s}' -> NOT USABLE", .{ src, resolved.name });
            if (resolved.source == .default) {
                std.debug.print(" (would fall back to PATH)\n", .{});
            } else {
                std.debug.print(" (HARD ERROR for explicit pins)\n", .{});
            }
            return 1;
        }
        return 0;
    }
    if (std.mem.eql(u8, cmd, "shim")) {
        var names: std.ArrayList([]const u8) = .empty;
        if (args.len >= 2) {
            for (args[1..]) |a| try names.append(gpa, a);
        } else {
            const lanes = try readLanes(io, gpa, env);
            try names.append(gpa, "zig");
            for (lanes) |lane| try names.append(gpa, lane.name);
        }
        return try installShims(io, gpa, names.items);
    }

    std.debug.print(
        \\zlane — the zig lane resolver
        \\
        \\  zlane set <name> <dir>    register a lane (validates the zig executable)
        \\  zlane remove <name>
        \\  zlane list
        \\  zlane default [name]
        \\  zlane shim [names...]     install shims next to this binary (default: zig + all lanes)
        \\  zlane which               what `zig` resolves to, and why
        \\  zlane path                just the resolved zig path
        \\  zlane doctor              diagnose the whole zig setup (lanes, PATH, env)
        \\
        \\  `zig` resolution: $ZIGUP_LANE > .ziglane (cwd and ancestors) > default lane > PATH
        \\  ($ZIGUP_LANE=path skips lanes; an explicit pin that is broken is an error,
        \\   only unset/broken-default falls back to PATH)
        \\
    , .{});
    return 0;
}

// ------------------------------------------------------------------ doctor

var doctor_failures: usize = 0;

fn ok(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("ok    " ++ fmt ++ "\n", args);
}
fn warn(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("WARN  " ++ fmt ++ "\n", args);
}
fn fail(comptime fmt: []const u8, args: anytype) void {
    doctor_failures += 1;
    std.debug.print("FAIL  " ++ fmt ++ "\n", args);
}

/// Run `<exe> version` and return its trimmed stdout, or null.
fn captureVersion(io: Io, gpa: std.mem.Allocator, exe: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ exe, "version" };
    var child = process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
        .environ_map = null,
    }) catch return null;
    var out: []const u8 = "";
    if (child.stdout) |*f| {
        var buf: [1]u8 = undefined;
        var fr = f.reader(io, &buf);
        out = fr.interface.allocRemaining(gpa, .limited(4096)) catch "";
        f.close(io);
    }
    const term = child.wait(io) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, out, " \r\n\t");
}

/// Cheap content sniff: does this candidate look like a lane-shim binary
/// rather than a real compiler? (searches the first 512 KiB for markers)
fn smellsLikeShim(io: Io, gpa: std.mem.Allocator, exe: []const u8) bool {
    const data = readFileSmall(io, gpa, exe, 16 << 20) orelse return false;
    for ([_][]const u8{ "ZLANE_FALLBACK_ACTIVE", "zigup lane set" }) |marker| {
        if (std.mem.indexOf(u8, data, marker) != null) return true;
    }
    return false;
}

fn doctor(io: Io, gpa: std.mem.Allocator, env: *const process.Environ.Map, argv0: []const u8) !u8 {
    doctor_failures = 0;
    std.debug.print("zlane doctor\n==========\n", .{});

    // 1. this binary
    const self_abs = selfPathAbs(io, gpa, argv0);
    if (Io.Dir.cwd().openFile(io, self_abs, .{})) |f| {
        f.close(io);
        ok("self: '{s}' (readable)", .{self_abs});
    } else |e| {
        fail("self: '{s}' is not a readable file: {t}", .{ self_abs, e });
    }
    if (selfDir(io, gpa, argv0)) |sd| {
        ok("self dir: {s}", .{sd});
    } else {
        warn("self dir: cannot derive from argv0 (PATH self-exclusion degraded)", .{});
    }

    // 2. lanes config
    const settings = try settingsDir(io, gpa, env);
    const lanes = try readLanes(io, gpa, env);
    if (settings) |dir| {
        std.debug.print("info  settings: {s} ({d} lanes)\n", .{ dir, lanes.len });
    } else {
        warn("no settings directory resolvable (no lanes; `zig` will always fall back to PATH)", .{});
    }
    for (lanes) |lane| {
        const zig = try zigExeIn(gpa, io, lane.dir);
        if (zig == null) {
            fail("lane '{s}': no zig executable in '{s}'", .{ lane.name, lane.dir });
            continue;
        }
        if (captureVersion(io, gpa, zig.?)) |v| {
            ok("lane '{s}': {s} -> {s}", .{ lane.name, zig.?, v });
        } else {
            fail("lane '{s}': '{s}' exists but `zig version` failed", .{ lane.name, zig.? });
        }
    }

    // 3. default lane
    if (try getDefaultLane(io, gpa, env)) |d| {
        if (findLane(lanes, d) == null) {
            fail("default lane '{s}' is not configured", .{d});
        }
    } else if (lanes.len > 0) {
        warn("no default lane set (`zig` with no pin falls back to PATH)", .{});
    }

    // 4. resolution trace (every source, winner marked)
    std.debug.print("info  resolution chain for `zig`:\n", .{});
    if (env.get("ZIGUP_LANE")) |v| {
        std.debug.print("info    $ZIGUP_LANE = '{s}'\n", .{std.mem.trim(u8, v, " \r\n\t")});
    } else std.debug.print("info    $ZIGUP_LANE unset\n", .{});
    if (findDotZiglane(io, gpa)) |pin| {
        std.debug.print("info    .ziglane = '{s}' (project pin)\n", .{pin});
    } else std.debug.print("info    no .ziglane in cwd or ancestors\n", .{});
    if (try getDefaultLane(io, gpa, env)) |d| {
        std.debug.print("info    default lane = '{s}'\n", .{d});
    } else std.debug.print("info    no default lane\n", .{});

    const resolved = try resolveLane(io, gpa, env);
    var resolved_exe: ?[]const u8 = null;
    if (resolved) |r| {
        const src = switch (r.source) {
            .env => "$ZIGUP_LANE",
            .project => ".ziglane",
            .default => "default lane",
        };
        const lane = findLane(lanes, r.name);
        const zig = if (lane) |l| try zigExeIn(gpa, io, l.dir) else null;
        if (zig) |z| {
            if (captureVersion(io, gpa, z)) |v| {
                ok("resolves ({s} -> lane '{s}'): {s} [{s}]", .{ src, r.name, z, v });
                resolved_exe = z;
            } else {
                if (r.source == .default) {
                    warn("resolves ({s} -> lane '{s}'): zig version FAILED; `zig` would fall back to PATH", .{ src, r.name });
                } else {
                    fail("resolves ({s} -> lane '{s}'): zig version FAILED (hard error for explicit pins)", .{ src, r.name });
                }
            }
        } else {
            if (r.source == .default) {
                warn("resolves ({s} -> lane '{s}'): lane not usable; `zig` would fall back to PATH", .{ src, r.name });
            } else {
                fail("resolves ({s} -> lane '{s}'): lane not configured/usable (hard error for explicit pins)", .{ src, r.name });
            }
        }
    } else {
        std.debug.print("info    nothing pinned — `zig` falls back to PATH\n", .{});
    }

    // 5. PATH scan (order matters; flag shims and the effective first)
    std.debug.print("info  `zig` candidates on PATH (in order):\n", .{});
    if (env.get("PATH")) |path_var| {
        const self_dir = selfDir(io, gpa, argv0);
        const exe_name = std.fmt.allocPrint(gpa, "zig{s}", .{exeExt()}) catch "zig";
        const sep: u8 = if (windows_host) ';' else ':';
        var entries = std.mem.splitScalar(u8, path_var, sep);
        var first = true;
        var found_any = false;
        while (entries.next()) |entry_raw| {
            const entry = trimTrailingSep(std.mem.trim(u8, entry_raw, " \""));
            if (entry.len == 0) continue;
            const candidate = std.fs.path.join(gpa, &.{ entry, exe_name }) catch continue;
            Io.Dir.cwd().access(io, candidate, .{}) catch continue;
            found_any = true;
            if (self_dir) |sd| {
                if (samePath(entry, sd)) {
                    std.debug.print("info    {s}   [this shim's dir — skipped for fallback]\n", .{candidate});
                    first = false;
                    continue;
                }
            }
            const shim = smellsLikeShim(io, gpa, candidate);
            if (first) {
                if (shim) {
                    fail("first zig on PATH is a lane shim: {s} (PATH fallback would dispatch through it — install a real zig ahead of it, or replace that shim)", .{candidate});
                } else {
                    ok("PATH fallback target: {s}{s}", .{ candidate, if (resolved_exe != null) " (unused while a lane resolves)" else "" });
                }
                first = false;
            } else if (shim) {
                warn("PATH contains a lane shim: {s}", .{candidate});
            } else {
                std.debug.print("info    {s}\n", .{candidate});
            }
        }
        if (!found_any) {
            if (resolved_exe == null) {
                fail("no zig anywhere: no lane resolves and none on PATH", .{});
            } else {
                warn("no zig on PATH (fine while lanes resolve; fallback would fail)", .{});
            }
        }
    } else {
        warn("no PATH in environment", .{});
    }

    // 6. cache env health (the classes that manufactured mystery failures)
    if (env.get("ZIG_GLOBAL_CACHE_DIR")) |g| {
        if (Io.Dir.cwd().access(io, trimTrailingSep(g), .{})) {
            ok("ZIG_GLOBAL_CACHE_DIR = {s}", .{g});
        } else |_| {
            // access() on a dir: fine if it opens as dir; try openDir
            if (Io.Dir.cwd().openDir(io, trimTrailingSep(g), .{})) |*d| {
                d.close(io);
                ok("ZIG_GLOBAL_CACHE_DIR = {s}", .{g});
            } else |_| {
                warn("ZIG_GLOBAL_CACHE_DIR = {s} does not exist (it will be created on first use)", .{g});
            }
        }
    } else if (windows_host) {
        warn("ZIG_GLOBAL_CACHE_DIR unset — compile children default to %LOCALAPPDATA%\\zig (check that pool is healthy; service shells do NOT inherit setx values)", .{});
    } else {
        std.debug.print("info  ZIG_GLOBAL_CACHE_DIR unset (zig default global cache)\n", .{});
    }
    if (env.get("ZIG_LOCAL_CACHE_DIR")) |l| {
        std.debug.print("info  ZIG_LOCAL_CACHE_DIR = {s}\n", .{l});
    }

    // verdict
    std.debug.print("----------\n", .{});
    if (doctor_failures == 0) {
        std.debug.print("doctor: all checks passed\n", .{});
        return 0;
    }
    std.debug.print("doctor: {d} FAIL(s)\n", .{doctor_failures});
    return 1;
}

fn installShims(io: Io, gpa: std.mem.Allocator, names: []const []const u8) !u8 {
    // Read our own executable via argv[0] (0.16-final std has no selfExe).
    var argv_it = try process.Args.Iterator.initAllocator(init_args, gpa);
    const argv0 = argv_it.next() orelse return fatal("no argv[0]", .{});
    const self_dir = selfDir(io, gpa, argv0) orelse return fatal("cannot determine this shim's directory from argv[0] ('{s}')", .{argv0});
    const self_data = readFileSmall(io, gpa, selfPathAbs(io, gpa, argv0), 64 << 20) orelse
        return fatal("cannot read this executable at '{s}' (is argv[0] the real path?)", .{argv0});
    for (names) |raw| {
        const name = basenameNoExe(raw);
        if (std.mem.eql(u8, name, "zlane")) continue;
        const dest = try std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ self_dir, std.fs.path.sep_str, name, exeExt() });
        var f = Io.Dir.cwd().createFile(io, dest, .{ .truncate = true }) catch |err| {
            std.debug.print("zlane: shim {s}: {t} (is it running?)\n", .{ dest, err });
            continue;
        };
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        w.interface.writeAll(self_data) catch |err| {
            std.debug.print("zlane: shim {s}: {t}\n", .{ dest, err });
            continue;
        };
        try w.interface.flush();
        std.debug.print("shim: {s}\n", .{dest});
    }
    return 0;
}

