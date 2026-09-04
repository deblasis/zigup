// lanes.zig — zigup lane support (2026-08-30 ccached project; 2026-09-04
// reborn against zig 0.16-final's Io std, semantics adopted verbatim from
// the standalone `zlane` resolver that was deployed and tested on three
// machines — that tool is retired by this port).
//
// A "lane" is a named compiler toolchain directory containing a `zig`
// executable (optionally `files/zig` for zigup-fetched toolchains). Lanes let
// one machine host several compiler lines — e.g. stable (official 0.16),
// ccached (0.16 + central cache), vigz (the fork) — with per-project and
// per-session selection, while keeping stock zigup behavior and conventions.
//
// `zig` resolution order (PROJECT-FIRST — multiple installs/requirements
// are per-project, so the committed pin is the contract):
//   1. .ziglane file in the cwd or an ancestor (project pin — also the
//      public "safe to use the fork here" marker)
//   2. $ZIGUP_LANE (session pin; the value `path` skips lanes entirely and
//      execs `zig` from PATH)
//   3. `zig` found on PATH, excluding the shim's own directory
//
// There is NO machine-wide default in the chain: an unpinned folder
// deliberately does NOT guess a lane, and a stale exported env var cannot
// hijack a pinned project (the file wins).
//
// Fallback discipline: only a source expressing NO intent falls back to
// PATH (no pin at all). An EXPLICIT pin (.ziglane or $ZIGUP_LANE naming an
// unregistered lane, or a lane dir without a zig executable) is a HARD
// ERROR: silently substituting a different compiler era is exactly the
// failure class lanes exist to prevent.
//
// Lane-named shims (`vigz`, `zig_ccached`, ...) always run exactly that
// lane; a broken one is a hard error.
//
// Shims are copies of the zigup executable named `zig` / `<lane>` /
// `zig_<lane>`; dispatch is by argv[0] basename, the convention zig itself
// uses. `zigup` (and `zlane`, for muscle memory) is the management CLI.
//
// Configuration (same files the zigup fork always used, so existing setups
// carry over): <settings>/lanes holds `name=dir` lines, and
// <settings>/lane-default is LEGACY — still written by `lane default` for
// compatibility but IGNORED by resolution. <settings> is
// $ZIGUP_SETTINGS|$ZLANE_SETTINGS, else %LOCALAPPDATA%\zigup on Windows,
// ~/Library/Application Support/zigup on macOS, $XDG_CONFIG_HOME or
// ~/.config /zigup elsewhere.

const std = @import("std");
const Io = std.Io;
const process = std.process;
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const Lane = struct {
    name: []const u8,
    dir: []const u8,
};

pub const LaneSource = enum { env, project, default };

pub const Resolved = struct {
    name: []const u8,
    source: LaneSource,
};

/// Everything the lane machinery needs from the process; populated once by
/// zigup's main (single-threaded CLI).
pub const Ctx = struct {
    io: Io,
    gpa: Allocator,
    env: *const process.Environ.Map,
    argv0: []const u8,
    /// Branding for output: the invoked name (e.g. `zigup`, or the shim
    /// name when dispatched through one).
    prog: []const u8,
    /// `--appdata` override (test machinery); wins over env/platform.
    appdata_override: ?[]const u8 = null,
};

fn fatal(ctx: Ctx, comptime fmt: []const u8, fmt_args: anytype) u8 {
    std.debug.print("{s}: ", .{ctx.prog});
    std.debug.print(fmt ++ "\n", fmt_args);
    return 0xff;
}

/// Data output (list/which/path/etc. — the scriptable results) goes to
/// stdout; diagnostics (doctor, usage) and errors stay on stderr.
fn out(ctx: Ctx, comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [4096]u8 = undefined;
    var f = Io.File.stdout();
    var w = f.writerStreaming(ctx.io, &buf);
    w.interface.print(fmt ++ "\n", fmt_args) catch return;
    w.interface.flush() catch return;
}

// ------------------------------------------------------------------ helpers

fn basenameNoExe(path: []const u8) []const u8 {
    var base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".exe")) base = base[0 .. base.len - 4];
    return base;
}

fn exeExt() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".exe",
        else => "",
    };
}

const windows_host = builtin.os.tag == .windows;

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
fn selfDir(ctx: Ctx) ?[]const u8 {
    // NOTE: fs.path.resolve can return a RELATIVE path when fed relative
    // inputs (resolve(".", "./x") -> "x") — anchor on the cwd so the result
    // is absolute, or PATH self-exclusion silently fails.
    const cwd = process.currentPathAlloc(ctx.io, ctx.gpa) catch return null;
    const abs = if (std.fs.path.isAbsolute(ctx.argv0))
        ctx.argv0
    else
        std.fs.path.resolve(ctx.gpa, &.{ cwd, ctx.argv0 }) catch return null;
    return trimTrailingSep(dirnameOf(abs) orelse return null);
}

/// argv0 made absolute (reads through the cwd handle choke on relative
/// "./x" forms on some hosts).
fn selfPathAbs(ctx: Ctx) []const u8 {
    var p: []const u8 = ctx.argv0;
    if (!std.fs.path.isAbsolute(p)) {
        const cwd = process.currentPathAlloc(ctx.io, ctx.gpa) catch return ctx.argv0;
        p = std.fs.path.resolve(ctx.gpa, &.{ cwd, p }) catch ctx.argv0;
    }
    // Windows: argv0 may arrive without the .exe extension.
    if (windows_host and !std.mem.endsWith(u8, p, ".exe")) {
        Io.Dir.cwd().access(ctx.io, p, .{}) catch {
            return std.fmt.allocPrint(ctx.gpa, "{s}.exe", .{p}) catch p;
        };
    }
    return p;
}

fn readFileSmall(ctx: Ctx, path: []const u8, max: usize) ?[]u8 {
    const cwd = Io.Dir.cwd();
    var f = cwd.openFile(ctx.io, path, .{}) catch return null;
    defer f.close(ctx.io);
    var buf: [1]u8 = undefined;
    var fr = f.reader(ctx.io, &buf);
    return fr.interface.allocRemaining(ctx.gpa, .limited(max)) catch null;
}

// ------------------------------------------------------------- settings I/O

pub fn settingsDir(ctx: Ctx) !?[]const u8 {
    if (ctx.appdata_override) |s| {
        if (s.len > 0) return s;
    }
    if (ctx.env.get("ZIGUP_SETTINGS")) |s| {
        if (s.len > 0) return s;
    }
    // the name the deployed resolver used; keep honoring it
    if (ctx.env.get("ZLANE_SETTINGS")) |s| {
        if (s.len > 0) return s;
    }
    if (windows_host) {
        const lad = ctx.env.get("LOCALAPPDATA") orelse return null;
        if (lad.len == 0) return null;
        return try std.fs.path.join(ctx.gpa, &.{ lad, "zigup" });
    }
    if (builtin.os.tag.isDarwin()) {
        const home = ctx.env.get("HOME") orelse return null;
        if (home.len == 0) return null;
        return try std.fs.path.join(ctx.gpa, &.{ home, "Library", "Application Support", "zigup" });
    }
    if (ctx.env.get("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return try std.fs.path.join(ctx.gpa, &.{ x, "zigup" });
    }
    if (ctx.env.get("HOME")) |home| {
        if (home.len > 0) return try std.fs.path.join(ctx.gpa, &.{ home, ".config", "zigup" });
    }
    return null;
}

pub fn readLanes(ctx: Ctx) ![]Lane {
    var list: std.ArrayList(Lane) = .empty;
    const dir = (try settingsDir(ctx)) orelse return list.toOwnedSlice(ctx.gpa);
    const path = try std.fs.path.join(ctx.gpa, &.{ dir, "lanes" });
    const data = readFileSmall(ctx, path, 1 << 20) orelse return list.toOwnedSlice(ctx.gpa);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " ");
        const ldir = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (name.len == 0 or ldir.len == 0) continue;
        try list.append(ctx.gpa, .{ .name = name, .dir = ldir });
    }
    return list.toOwnedSlice(ctx.gpa);
}

pub fn saveLanes(ctx: Ctx, lanes: []const Lane) !void {
    const dir = (try settingsDir(ctx)) orelse return error.NoSettingsDir;
    try Io.Dir.cwd().createDirPath(ctx.io, dir);
    const path = try std.fs.path.join(ctx.gpa, &.{ dir, "lanes" });
    var f = try Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = true });
    defer f.close(ctx.io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(ctx.io, &buf);
    for (lanes) |lane| {
        try w.interface.print("{s}={s}\n", .{ lane.name, lane.dir });
    }
    try w.interface.flush();
}

/// Legacy file: written by `lane default` for compatibility, IGNORED by
/// resolution (resolution is .ziglane-first; unpinned folders use PATH).
pub fn getDefaultLane(ctx: Ctx) !?[]const u8 {
    const dir = (try settingsDir(ctx)) orelse return null;
    const path = try std.fs.path.join(ctx.gpa, &.{ dir, "lane-default" });
    const data = readFileSmall(ctx, path, 4096) orelse return null;
    const trimmed = std.mem.trim(u8, data, " \r\n\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

pub fn setDefaultLane(ctx: Ctx, name: []const u8) !void {
    const dir = (try settingsDir(ctx)) orelse return error.NoSettingsDir;
    try Io.Dir.cwd().createDirPath(ctx.io, dir);
    const path = try std.fs.path.join(ctx.gpa, &.{ dir, "lane-default" });
    var f = try Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = true });
    defer f.close(ctx.io);
    var buf: [256]u8 = undefined;
    var w = f.writer(ctx.io, &buf);
    try w.interface.print("{s}\n", .{name});
    try w.interface.flush();
}

// ---------------------------------------------------------------- resolution

pub fn findLane(lanes: []const Lane, name: []const u8) ?Lane {
    for (lanes) |lane| {
        if (std.mem.eql(u8, lane.name, name)) return lane;
    }
    return null;
}

fn findDotZiglane(ctx: Ctx) ?[]const u8 {
    const cwd_alloc = process.currentPathAlloc(ctx.io, ctx.gpa) catch return null;
    var dir: []const u8 = trimTrailingSep(cwd_alloc);
    var depth: usize = 0;
    while (depth < 24) : (depth += 1) {
        const candidate = std.fs.path.join(ctx.gpa, &.{ dir, ".ziglane" }) catch return null;
        if (readFileSmall(ctx, candidate, 4096)) |data| {
            const trimmed = std.mem.trim(u8, data, " \r\n\t");
            // An EMPTY marker is not a pin: keep walking so a nested
            // project inherits the ancestor's lane, and only a tree with
            // no non-empty marker anywhere defers to $ZIGUP_LANE/PATH.
            if (trimmed.len > 0) return trimmed;
        }
        const parent = dirnameOf(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
    return null;
}

/// Resolve the lane name in force for the current context. `null` = nothing
/// expressed (caller falls back to PATH). PROJECT-FIRST: the committed
/// .ziglane is the contract and beats any ambient shell state. No
/// machine-wide default participates.
pub fn resolveLane(ctx: Ctx) !?Resolved {
    if (findDotZiglane(ctx)) |from_file| return .{ .name = from_file, .source = .project };
    if (ctx.env.get("ZIGUP_LANE")) |v| {
        const trimmed = std.mem.trim(u8, v, " \r\n\t");
        if (trimmed.len > 0) return .{ .name = trimmed, .source = .env };
        return null;
    }
    return null;
}

// ---------------------------------------------------------------------- exec

/// Path of a lane's zig executable (lane_dir/zig or lane_dir/files/zig), or
/// null when the lane is unusable.
pub fn zigExeIn(ctx: Ctx, lane_dir: []const u8) !?[]const u8 {
    const exe_name = try std.fmt.allocPrint(ctx.gpa, "zig{s}", .{exeExt()});
    const direct = try std.fs.path.join(ctx.gpa, &.{ lane_dir, exe_name });
    Io.Dir.cwd().access(ctx.io, direct, .{}) catch {
        const files = try std.fs.path.join(ctx.gpa, &.{ lane_dir, "files", exe_name });
        Io.Dir.cwd().access(ctx.io, files, .{}) catch return null;
        return files;
    };
    return direct;
}

fn execZig(ctx: Ctx, zig_path: []const u8, passthrough: []const []const u8) !u8 {
    const argv = try ctx.gpa.alloc([]const u8, 1 + passthrough.len);
    argv[0] = zig_path;
    for (passthrough, 0..) |a, i| argv[1 + i] = a;
    var child = process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = null, // inherit
    }) catch |err| return fatal(ctx, "failed to spawn '{s}': {t}", .{ zig_path, err });
    const term = child.wait(ctx.io) catch |err| return fatal(ctx, "wait on '{s}' failed: {t}", .{ zig_path, err });
    switch (term) {
        .exited => |code| return code,
        else => |t| return fatal(ctx, "'{s}' terminated abnormally: {t}", .{ zig_path, t }),
    }
}

/// Find `zig` on PATH, skipping the directory our own shims live in (the
/// `zig` shim is itself named zig — matching it would loop).
pub fn findZigOnPath(ctx: Ctx, argv0: []const u8) !?[]const u8 {
    const path_var = ctx.env.get("PATH") orelse return null;
    const self_dir = selfDirFrom(ctx, argv0);
    const exe_name = try std.fmt.allocPrint(ctx.gpa, "zig{s}", .{exeExt()});
    const sep: u8 = if (windows_host) ';' else ':';
    var entries = std.mem.splitScalar(u8, path_var, sep);
    while (entries.next()) |entry_raw| {
        const entry = trimTrailingSep(std.mem.trim(u8, entry_raw, " \""));
        if (entry.len == 0) continue;
        if (self_dir) |sd| {
            if (samePath(entry, sd)) continue;
        }
        const candidate = try std.fs.path.join(ctx.gpa, &.{ entry, exe_name });
        Io.Dir.cwd().access(ctx.io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

/// Like `selfDir` but for an explicit argv0 (the CLI subcommands probe PATH
/// from the `zigup` process itself).
fn selfDirFrom(ctx: Ctx, argv0: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, argv0, ctx.argv0)) return selfDir(ctx);
    const cwd = process.currentPathAlloc(ctx.io, ctx.gpa) catch return null;
    const abs = if (std.fs.path.isAbsolute(argv0))
        argv0
    else
        std.fs.path.resolve(ctx.gpa, &.{ cwd, argv0 }) catch return null;
    return trimTrailingSep(dirnameOf(abs) orelse return null);
}

// Loop guard: if this process was itself reached via a PATH fallback and the
// fallback resolves to us again, bail instead of spawning forever. Also the
// content marker `doctor` uses to recognize our own family of shims.
pub const guard_env = "ZLANE_FALLBACK_ACTIVE";

fn execPathFallback(ctx: Ctx, passthrough: []const []const u8) !u8 {
    if (ctx.env.get(guard_env) != null)
        return fatal(ctx, "PATH fallback loop detected (this shim IS the zig on PATH)", .{});
    const zig_path = (try findZigOnPath(ctx, ctx.argv0)) orelse
        return fatal(ctx, "no lane resolved and no zig found on PATH", .{});
    const argv = try ctx.gpa.alloc([]const u8, 1 + passthrough.len);
    argv[0] = zig_path;
    for (passthrough, 0..) |a, i| argv[1 + i] = a;

    // Set the guard in the child environment.
    var env_copy = process.Environ.Map.init(ctx.gpa);
    defer env_copy.deinit();
    for (ctx.env.keys(), ctx.env.values()) |key, value| {
        try env_copy.put(key, value);
    }
    try env_copy.put(guard_env, "1");

    var child = process.spawn(ctx.io, .{
        .argv = argv,
        .environ_map = &env_copy,
    }) catch |err| return fatal(ctx, "failed to spawn '{s}': {t}", .{ zig_path, err });
    const term = child.wait(ctx.io) catch |err| return fatal(ctx, "wait on '{s}' failed: {t}", .{ zig_path, err });
    switch (term) {
        .exited => |code| return code,
        else => |t| return fatal(ctx, "'{s}' terminated abnormally: {t}", .{ zig_path, t }),
    }
}

// ------------------------------------------------------------ shim dispatch

/// If this process was launched through a shim (argv0 `zig` or a lane name),
/// dispatch to the resolved compiler and return the exit code. Returns null
/// when running as the management CLI (`zigup`/`zlane`).
pub fn shimDispatch(ctx: Ctx, args: []const []const u8) !?u8 {
    const base = basenameNoExe(ctx.argv0);
    if (std.mem.eql(u8, base, "zigup") or std.mem.eql(u8, base, "zlane")) return null;

    return try shimDispatchAs(ctx, base, args);
}

/// Dispatch as if invoked with the given base name (`zig`, a lane name, ...).
pub fn shimDispatchAs(ctx: Ctx, base: []const u8, args: []const []const u8) !u8 {
    const lanes = try readLanes(ctx);

    if (!std.mem.eql(u8, base, "zig")) {
        // A lane-named shim: `vigz` or `zig_ccached`. Explicit: never falls
        // back.
        var lane_name = base;
        if (findLane(lanes, lane_name) == null and std.mem.startsWith(u8, base, "zig_")) {
            lane_name = base[4..];
        }
        const lane = findLane(lanes, lane_name) orelse
            return fatal(ctx, "lane '{s}' is not configured (fix: {s} lane set {s} <dir>)", .{ lane_name, ctx.prog, lane_name });
        const zig_path = (try zigExeIn(ctx, lane.dir)) orelse
            return fatal(ctx, "lane '{s}' has no zig executable in '{s}'", .{ lane_name, lane.dir });
        return try execZig(ctx, zig_path, args);
    }

    // The `zig` shim.
    const resolved = (try resolveLane(ctx)) orelse {
        // No pin anywhere: PATH, never a machine-wide guess.
        return try execPathFallback(ctx, args);
    };
    if (resolved.source == .env and std.mem.eql(u8, resolved.name, "path")) {
        return try execPathFallback(ctx, args);
    }
    const lane = findLane(lanes, resolved.name);
    const zig_path = if (lane) |l| try zigExeIn(ctx, l.dir) else null;
    if (zig_path == null) {
        return fatal(
            ctx,
            "lane '{s}' (from {s}) is not configured or has no zig executable; refusing to substitute another compiler (fix: {s} lane set {s} <dir>)",
            .{ resolved.name, switch (resolved.source) {
                .env => "$ZIGUP_LANE",
                .project => ".ziglane",
                .default => "default lane",
            }, ctx.prog, resolved.name },
        );
    }
    return try execZig(ctx, zig_path.?, args);
}

/// `zigup run ...` — exactly what the `zig` shim would do.
pub fn runAsZig(ctx: Ctx, args: []const []const u8) !u8 {
    return try shimDispatchAs(ctx, "zig", args);
}

// ----------------------------------------------------------------- the CLI

/// Lane-management subcommands (the words after `zigup lane`, or a whole
/// `zigup doctor|which|path` line via `cmd`).
pub fn cli(ctx: Ctx, args: []const []const u8) !u8 {
    const cmd = if (args.len > 0) args[0] else "";

    if (std.mem.eql(u8, cmd, "doctor")) {
        return try doctor(ctx);
    }
    if (std.mem.eql(u8, cmd, "run")) {
        // `zigup run ...` = exactly what the `zig` shim would do.
        return try runAsZig(ctx, args[1..]);
    }

    if (std.mem.eql(u8, cmd, "list")) {
        const lanes = try readLanes(ctx);
        const def = try getDefaultLane(ctx);
        for (lanes) |lane| {
            const marker = if (def != null and std.mem.eql(u8, def.?, lane.name)) " (default)" else "";
            out(ctx, "{s}{s}\t{s}", .{ lane.name, marker, lane.dir });
        }
        if (def == null and lanes.len > 0) out(ctx, "(no default lane set)", .{});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "set")) {
        if (args.len < 3) return fatal(ctx, "usage: {s} lane set <name> <dir>", .{ctx.prog});
        return try laneSet(ctx, args[1], args[2]);
    }
    if (std.mem.eql(u8, cmd, "remove")) {
        if (args.len < 2) return fatal(ctx, "usage: {s} lane remove <name>", .{ctx.prog});
        return try laneRemove(ctx, args[1]);
    }
    if (std.mem.eql(u8, cmd, "default")) {
        std.debug.print("{s}: `default` is DEPRECATED and ignored — resolution is .ziglane-first (.ziglane > $ZIGUP_LANE > PATH); there is no machine-wide default\n", .{ctx.prog});
        if (args.len >= 2) {
            const lanes = try readLanes(ctx);
            if (findLane(lanes, args[1]) == null) return fatal(ctx, "lane '{s}' is not configured", .{args[1]});
            try setDefaultLane(ctx, args[1]);
            out(ctx, "default lane: {s}", .{args[1]});
            return 0;
        }
        if (try getDefaultLane(ctx)) |d| {
            out(ctx, "{s}", .{d});
            return 0;
        }
        return fatal(ctx, "no default lane set", .{});
    }
    if (std.mem.eql(u8, cmd, "which") or std.mem.eql(u8, cmd, "path")) {
        return try which(ctx, std.mem.eql(u8, cmd, "path"));
    }
    if (std.mem.eql(u8, cmd, "shim")) {
        var names: std.ArrayList([]const u8) = .empty;
        if (args.len >= 2) {
            for (args[1..]) |a| try names.append(ctx.gpa, a);
        } else {
            const lanes = try readLanes(ctx);
            try names.append(ctx.gpa, "zig");
            for (lanes) |lane| try names.append(ctx.gpa, lane.name);
        }
        return try shimInstall(ctx, names.items);
    }

    usage(ctx);
    return 0;
}

fn usage(ctx: Ctx) void {
    const p = ctx.prog;
    std.debug.print(
        \\{s} — the zig lane resolver
        \\
        \\  {s} lane set <name> <dir>  register a lane (validates the zig executable)
        \\  {s} lane remove <name>
        \\  {s} lane list
        \\  {s} lane default [name]   DEPRECATED: ignored (resolution is .ziglane-first)
        \\  {s} lane shim [names...]   install shims next to this binary (default: zig + all lanes)
        \\  {s} which                  what `zig` resolves to, and why
        \\  {s} path                   just the resolved zig path
        \\  {s} doctor                 diagnose the whole zig setup (lanes, PATH, env)
        \\  {s} lane run [args...]      act as the `zig` shim
        \\
        \\  `zig` resolution: .ziglane (cwd and ancestors) > $ZIGUP_LANE > PATH
        \\  (project-first, NO machine-wide default; $ZIGUP_LANE=path skips lanes;
        \\   an explicit pin that is broken is an error, never a substitution)
        \\
    , .{ p, p, p, p, p, p, p, p, p, p });
}

// -------------------------------------------------------------- which/path

pub fn which(ctx: Ctx, scriptable: bool) !u8 {
    const lanes = try readLanes(ctx);
    const resolved = (try resolveLane(ctx)) orelse {
        const p = try findZigOnPath(ctx, "zig");
        if (p) |zig| {
            if (scriptable) {
                out(ctx, "{s}", .{zig});
            } else out(ctx, "path-fallback (no lane resolved): {s}", .{zig});
            return 0;
        }
        return fatal(ctx, "nothing resolves: no lane and no zig on PATH", .{});
    };
    if (resolved.source == .env and std.mem.eql(u8, resolved.name, "path")) {
        const p = try findZigOnPath(ctx, "zig");
        if (p) |zig| {
            if (scriptable) {
                out(ctx, "{s}", .{zig});
            } else out(ctx, "$ZIGUP_LANE=path: {s}", .{zig});
            return 0;
        }
        return fatal(ctx, "$ZIGUP_LANE=path but no zig on PATH", .{});
    }
    const lane = findLane(lanes, resolved.name);
    const zig = if (lane) |l| try zigExeIn(ctx, l.dir) else null;
    const src = switch (resolved.source) {
        .env => "$ZIGUP_LANE",
        .project => ".ziglane",
        .default => "default lane",
    };
    if (zig) |z| {
        if (scriptable) {
            out(ctx, "{s}", .{z});
        } else out(ctx, "{s}: lane '{s}' -> {s}", .{ src, resolved.name, z });
    } else {
        if (resolved.source == .default) {
            out(ctx, "{s}: lane '{s}' -> NOT USABLE (would fall back to PATH)", .{ src, resolved.name });
        } else {
            out(ctx, "{s}: lane '{s}' -> NOT USABLE (HARD ERROR for explicit pins)", .{ src, resolved.name });
        }
        return 1;
    }
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
fn captureVersion(ctx: Ctx, exe: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ exe, "version" };
    var child = process.spawn(ctx.io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
        .environ_map = null,
    }) catch return null;
    var child_out: []const u8 = "";
    if (child.stdout) |*f| {
        var buf: [1]u8 = undefined;
        var fr = f.reader(ctx.io, &buf);
        child_out = fr.interface.allocRemaining(ctx.gpa, .limited(4096)) catch "";
        f.close(ctx.io);
    }
    const term = child.wait(ctx.io) catch return null;
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, child_out, " \r\n\t");
}

/// Cheap content sniff: does this candidate look like a lane-shim binary
/// rather than a real compiler? (searches the first 16 MiB for markers)
const ShimSmell = enum { not_a_shim, zlane, foreign };

fn smellShim(ctx: Ctx, exe: []const u8) ShimSmell {
    const data = readFileSmall(ctx, exe, 16 << 20) orelse return .not_a_shim;
    // zlane/zigup-family binaries carry the guard-env marker; the old zigup
    // fork carries its usage text. One of ours on PATH is fine (it chains
    // correctly and is loop-guarded); a foreign one FAILs fallbacks.
    if (std.mem.indexOf(u8, data, guard_env) != null) return .zlane;
    if (std.mem.indexOf(u8, data, "zigup lane set") != null) return .foreign;
    return .not_a_shim;
}

pub fn doctor(ctx: Ctx) !u8 {
    doctor_failures = 0;
    std.debug.print("{s} doctor\n==========\n", .{ctx.prog});

    // 1. this binary
    const self_abs = selfPathAbs(ctx);
    if (Io.Dir.cwd().openFile(ctx.io, self_abs, .{})) |f| {
        f.close(ctx.io);
        ok("self: '{s}' (readable)", .{self_abs});
    } else |e| {
        fail("self: '{s}' is not a readable file: {t}", .{ self_abs, e });
    }
    if (selfDir(ctx)) |sd| {
        ok("self dir: {s}", .{sd});
    } else {
        warn("self dir: cannot derive from argv0 (PATH self-exclusion degraded)", .{});
    }

    // 2. lanes config
    const settings = try settingsDir(ctx);
    const lanes = try readLanes(ctx);
    if (settings) |dir| {
        std.debug.print("info  settings: {s} ({d} lanes)\n", .{ dir, lanes.len });
    } else {
        warn("no settings directory resolvable (no lanes; `zig` will always fall back to PATH)", .{});
    }
    for (lanes) |lane| {
        const zig = try zigExeIn(ctx, lane.dir);
        if (zig == null) {
            fail("lane '{s}': no zig executable in '{s}'", .{ lane.name, lane.dir });
            continue;
        }
        if (captureVersion(ctx, zig.?)) |v| {
            ok("lane '{s}': {s} -> {s}", .{ lane.name, zig.?, v });
        } else {
            fail("lane '{s}': '{s}' exists but `zig version` failed", .{ lane.name, zig.? });
        }
    }

    // 3. legacy default-lane file (no longer part of resolution)
    if (try getDefaultLane(ctx)) |_| {
        std.debug.print("info  a legacy lane-default file exists — IGNORED (resolution is .ziglane-first; unpinned folders use PATH)\n", .{});
    }

    // 4. resolution trace (every source, winner marked)
    std.debug.print("info  resolution chain for `zig`:\n", .{});
    if (findDotZiglane(ctx)) |pin| {
        std.debug.print("info    .ziglane = '{s}' (project pin — wins)\n", .{pin});
    } else std.debug.print("info    no .ziglane in cwd or ancestors\n", .{});
    if (ctx.env.get("ZIGUP_LANE")) |v| {
        std.debug.print("info    $ZIGUP_LANE = '{s}'\n", .{std.mem.trim(u8, v, " \r\n\t")});
    } else std.debug.print("info    $ZIGUP_LANE unset\n", .{});

    const resolved = try resolveLane(ctx);
    var resolved_exe: ?[]const u8 = null;
    if (resolved) |r| {
        const src = switch (r.source) {
            .env => "$ZIGUP_LANE",
            .project => ".ziglane",
            .default => "default lane",
        };
        const lane = findLane(lanes, r.name);
        const zig = if (lane) |l| try zigExeIn(ctx, l.dir) else null;
        if (zig) |z| {
            if (captureVersion(ctx, z)) |v| {
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
    if (ctx.env.get("PATH")) |path_var| {
        const self_dir = selfDir(ctx);
        const exe_name = std.fmt.allocPrint(ctx.gpa, "zig{s}", .{exeExt()}) catch "zig";
        const sep: u8 = if (windows_host) ';' else ':';
        var entries = std.mem.splitScalar(u8, path_var, sep);
        var first = true;
        var found_any = false;
        while (entries.next()) |entry_raw| {
            const entry = trimTrailingSep(std.mem.trim(u8, entry_raw, " \""));
            if (entry.len == 0) continue;
            const candidate = std.fs.path.join(ctx.gpa, &.{ entry, exe_name }) catch continue;
            Io.Dir.cwd().access(ctx.io, candidate, .{}) catch continue;
            found_any = true;
            if (self_dir) |sd| {
                if (samePath(entry, sd)) {
                    std.debug.print("info    {s}   [this shim's dir — skipped for fallback]\n", .{candidate});
                    first = false;
                    continue;
                }
            }
            const smell = smellShim(ctx, candidate);
            if (first) {
                switch (smell) {
                    .foreign => fail("first zig on PATH is a FOREIGN lane shim: {s} (PATH fallback would dispatch through it and fail — install a real zig ahead of it, or replace that shim)", .{candidate}),
                    .zlane => ok("PATH fallback target: {s} [a {s}-family shim — chains correctly]{s}", .{ candidate, ctx.prog, if (resolved_exe != null) " (unused while a lane resolves)" else "" }),
                    .not_a_shim => ok("PATH fallback target: {s}{s}", .{ candidate, if (resolved_exe != null) " (unused while a lane resolves)" else "" }),
                }
                first = false;
            } else switch (smell) {
                .foreign => warn("PATH contains a foreign lane shim: {s}", .{candidate}),
                .zlane => std.debug.print("info    {s}   [{s}-family shim]\n", .{ candidate, ctx.prog }),
                .not_a_shim => std.debug.print("info    {s}\n", .{candidate}),
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
    if (ctx.env.get("ZIG_GLOBAL_CACHE_DIR")) |g| {
        if (Io.Dir.cwd().openDir(ctx.io, trimTrailingSep(g), .{})) |*d| {
            d.close(ctx.io);
            ok("ZIG_GLOBAL_CACHE_DIR = {s}", .{g});
        } else |_| {
            warn("ZIG_GLOBAL_CACHE_DIR = {s} does not exist (it will be created on first use)", .{g});
        }
    } else if (windows_host) {
        warn("ZIG_GLOBAL_CACHE_DIR unset — compile children default to %LOCALAPPDATA%\\zig (check that pool is healthy; service shells do NOT inherit setx values)", .{});
    } else {
        std.debug.print("info  ZIG_GLOBAL_CACHE_DIR unset (zig default global cache)\n", .{});
    }
    if (ctx.env.get("ZIG_LOCAL_CACHE_DIR")) |l| {
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

// ----------------------------------------------------------------- shims

/// Copy this executable next to itself under `name` (and `name.exe` on
/// Windows), creating a lane dispatch shim. copyFile preserves the
/// executable permission bits (a hand-rolled create+writeAll does not).
pub fn shimInstall(ctx: Ctx, names: []const []const u8) !u8 {
    const self_dir = selfDir(ctx) orelse
        return fatal(ctx, "cannot determine this shim's directory from argv0 ('{s}')", .{ctx.argv0});
    const self_path = selfPathAbs(ctx);
    Io.Dir.cwd().access(ctx.io, self_path, .{}) catch
        return fatal(ctx, "cannot read this executable at '{s}' (is argv0 the real path?)", .{self_path});
    for (names) |raw| {
        const name = basenameNoExe(raw);
        if (std.mem.eql(u8, name, "zigup") or std.mem.eql(u8, name, "zlane")) continue;
        const dest = try std.fmt.allocPrint(ctx.gpa, "{s}{s}{s}{s}", .{ self_dir, std.fs.path.sep_str, name, exeExt() });
        // remove a previous shim first so the copy's link() doesn't hit
        // PathAlreadyExists
        Io.Dir.cwd().deleteFile(ctx.io, dest) catch {};
        Io.Dir.copyFileAbsolute(self_path, dest, ctx.io, .{ .replace = true }) catch |err| {
            std.debug.print("{s}: shim {s}: {t} (is it running?)\n", .{ ctx.prog, dest, err });
            continue;
        };
        out(ctx, "shim: {s}", .{dest});
    }
    return 0;
}

// ------------------------------------------------------------ subcommands

pub fn laneSet(ctx: Ctx, name: []const u8, dir_in: []const u8) !u8 {
    var dir = dir_in;
    if (!std.fs.path.isAbsolute(dir)) {
        const cwd = process.currentPathAlloc(ctx.io, ctx.gpa) catch dir;
        dir = std.fs.path.join(ctx.gpa, &.{ cwd, dir }) catch dir;
    }
    if ((try zigExeIn(ctx, dir)) == null)
        return fatal(ctx, "'{s}' contains no zig executable (looked for zig{s} and files/zig{s})", .{ dir, exeExt(), exeExt() });
    const lanes = try readLanes(ctx);
    var updated: std.ArrayList(Lane) = .empty;
    var replaced = false;
    for (lanes) |lane| {
        if (std.mem.eql(u8, lane.name, name)) {
            try updated.append(ctx.gpa, .{ .name = name, .dir = dir });
            replaced = true;
        } else try updated.append(ctx.gpa, lane);
    }
    if (!replaced) try updated.append(ctx.gpa, .{ .name = name, .dir = dir });
    try saveLanes(ctx, updated.items);
    out(ctx, "lane '{s}' -> {s}", .{ name, dir });
    return 0;
}

pub fn laneRemove(ctx: Ctx, name: []const u8) !u8 {
    const lanes = try readLanes(ctx);
    var updated: std.ArrayList(Lane) = .empty;
    var removed = false;
    for (lanes) |lane| {
        if (std.mem.eql(u8, lane.name, name)) {
            removed = true;
        } else try updated.append(ctx.gpa, lane);
    }
    if (!removed) return fatal(ctx, "lane '{s}' is not configured", .{name});
    try saveLanes(ctx, updated.items);
    out(ctx, "lane '{s}' removed", .{name});
    return 0;
}
