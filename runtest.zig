const builtin = @import("builtin");
const std = @import("std");
const process = std.process;
const Io = std.Io;

const fixdeletetree = @import("fixdeletetree.zig");

const exe_ext = builtin.os.tag.exeFileExt(builtin.cpu.arch);

fn compilersArg(arg: []const u8) []const u8 {
    return if (std.mem.eql(u8, arg, "--no-compilers")) "" else arg;
}

pub fn main(init: process.Init) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const io = init.io;

    var all_args: std.ArrayList([]const u8) = .empty;
    {
        var it = try process.Args.Iterator.initAllocator(init.minimal.args, arena);
        while (it.next()) |a| try all_args.append(arena, a);
    }
    if (all_args.items.len < 9) @panic("not enough cmdline args");

    const test_name = all_args.items[1];
    const add_path_option = all_args.items[2];
    const in_env_dir = all_args.items[3];
    const with_compilers = compilersArg(all_args.items[4]);
    const keep_compilers = compilersArg(all_args.items[5]);
    const out_env_dir = all_args.items[6];
    const setup_option = all_args.items[7];
    const zigup_exe = all_args.items[8];
    const zigup_args = all_args.items[9..];

    const add_path = blk: {
        if (std.mem.eql(u8, add_path_option, "--with-path")) break :blk true;
        if (std.mem.eql(u8, add_path_option, "--no-path")) break :blk false;
        std.log.err("expected '--with-path' or '--no-path' but got '{s}'", .{add_path_option});
        std.process.exit(0xff);
    };

    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, out_env_dir) catch {};
    try cwd.createDir(io, out_env_dir, .default_dir);

    // make a file named after the test so we can find this directory in the cache
    _ = test_name;

    const appdata = try std.fs.path.join(arena, &.{ out_env_dir, "appdata" });
    const path_link = try std.fs.path.join(arena, &.{ out_env_dir, "zig" ++ exe_ext });
    const install_dir = try std.fs.path.join(arena, &.{ out_env_dir, "install" });
    const install_dir_parsed = switch (parseInstallDir(install_dir)) {
        .good => |p| p,
        .bad => |reason| std.debug.panic("failed to parse install dir '{s}': {s}", .{ install_dir, reason }),
    };

    const install_dir_setting_path = try std.fs.path.join(arena, &.{ appdata, "install-dir" });

    if (std.mem.eql(u8, in_env_dir, "--no-input-environment")) {
        try cwd.createDir(io, install_dir, .default_dir);
        try cwd.createDir(io, appdata, .default_dir);
        var file = try cwd.createFile(io, install_dir_setting_path, .{});
        defer file.close(io);
        var fw = file.writerStreaming(io, &.{});
        try fw.interface.writeAll(install_dir);
        try fw.interface.flush();
    } else {
        var shared_sibling_state: SharedSiblingState = .{};
        try copyEnvDir(
            io,
            arena,
            in_env_dir,
            out_env_dir,
            in_env_dir,
            out_env_dir,
            .{ .with_compilers = with_compilers },
            &shared_sibling_state,
        );

        const input_install_dir = blk: {
            var file = try cwd.openFile(io, install_dir_setting_path, .{});
            defer file.close(io);
            var buf: [1]u8 = undefined;
            var fr = file.reader(io, &buf);
            break :blk try fr.interface.allocRemaining(arena, .limited(std.math.maxInt(u32)));
        };
        switch (parseInstallDir(input_install_dir)) {
            .good => |input_install_dir_parsed| {
                std.debug.assert(std.mem.eql(u8, install_dir_parsed.cache_o, input_install_dir_parsed.cache_o));
                var file = try cwd.createFile(io, install_dir_setting_path, .{ .truncate = true });
                defer file.close(io);
                var fw = file.writerStreaming(io, &.{});
                try fw.interface.writeAll(install_dir);
                try fw.interface.flush();
            },
            .bad => {
                // the install dir must have been customized, keep it
            },
        }
    }

    var maybe_second_bin_dir: ?[]const u8 = null;

    if (std.mem.eql(u8, setup_option, "no-extra-setup")) {
        // nothing extra to setup
    } else if (std.mem.eql(u8, setup_option, "path-link-is-directory")) {
        cwd.deleteFile(io, path_link) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };
        try cwd.createDir(io, path_link, .default_dir);
    } else if (std.mem.eql(u8, setup_option, "another-zig")) {
        maybe_second_bin_dir = try std.fs.path.join(arena, &.{ out_env_dir, "bin2" });
        try cwd.createDir(io, maybe_second_bin_dir.?, .default_dir);

        const fake_zig = try std.fs.path.join(arena, &.{
            maybe_second_bin_dir.?,
            "zig" ++ comptime builtin.target.exeFileExt(),
        });
        var file = try cwd.createFile(io, fake_zig, .{});
        defer file.close(io);
        var fw = file.writerStreaming(io, &.{});
        try fw.interface.writeAll("a fake executable");
        try fw.interface.flush();
    } else {
        std.log.err("unknown setup option '{s}'", .{setup_option});
        std.process.exit(0xff);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, zigup_exe);
    try argv.append(arena, "--appdata");
    try argv.append(arena, appdata);
    try argv.append(arena, "--path-link");
    try argv.append(arena, path_link);
    try argv.appendSlice(arena, zigup_args);

    {
        var err_file = Io.File.stderr();
        var buf: [512]u8 = undefined;
        var w = err_file.writerStreaming(io, &buf);
        try w.interface.writeAll("runtest exec:");
        for (argv.items) |arg| {
            try w.interface.print(" {s}", .{arg});
        }
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }

    if (add_path) {
        // make sure the directory with our path-link comes first in PATH
        var env_map = process.Environ.Map.init(arena);
        for (init.environ_map.keys(), init.environ_map.values()) |key, value| {
            try env_map.put(key, value);
        }
        var new_path: std.ArrayList(u8) = .empty;
        if (maybe_second_bin_dir) |second_bin_dir| {
            try new_path.appendSlice(arena, second_bin_dir);
            try new_path.append(arena, std.fs.path.delimiter);
        }
        try new_path.appendSlice(arena, out_env_dir);
        try new_path.append(arena, std.fs.path.delimiter);
        if (env_map.get("PATH")) |path| {
            try new_path.appendSlice(arena, path);
        }
        try env_map.put("PATH", new_path.items);

        var child = try process.spawn(io, .{
            .argv = argv.items,
            .environ_map = &env_map,
        });
        const result = try child.wait(io);
        switch (result) {
            .exited => |c| if (c != 0) std.process.exit(c),
            else => |sig| {
                std.log.err("zigup terminated from '{s}' with {any}", .{ @tagName(result), sig });
                std.process.exit(0xff);
            },
        }
    } else {
        if (maybe_second_bin_dir) |_| @panic("invalid config");
        var child = try process.spawn(io, .{
            .argv = argv.items,
            .environ_map = null,
        });
        const result = try child.wait(io);
        switch (result) {
            .exited => |c| if (c != 0) std.process.exit(c),
            else => |sig| {
                std.log.err("zigup terminated from '{s}' with {any}", .{ @tagName(result), sig });
                std.process.exit(0xff);
            },
        }
    }

    {
        var dir = try cwd.openDir(io, install_dir, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |install_entry| {
            switch (install_entry.kind) {
                .directory => {},
                else => continue,
            }
            if (std.mem.endsWith(u8, install_entry.name, ".installing")) {
                // leftover from an interrupted/cancelled install — delete it
                // so the env self-heals instead of poisoning dependent tests
                std.log.info("deleting leftover '{s}'", .{install_entry.name});
                try fixdeletetree.deleteTree(dir, io, install_entry.name);
                continue;
            }
            if (containsCompiler(keep_compilers, install_entry.name)) {
                std.log.info("keeping compiler '{s}'", .{install_entry.name});
                continue;
            }
            const files_path = try std.fs.path.join(arena, &.{ install_entry.name, "files" });
            // a compiler dir copied with --no-compilers has an empty (or,
            // after partial copies, missing) files dir — nothing to clean
            var files_dir = dir.openDir(io, files_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer files_dir.close(io);
            var files_it = files_dir.iterate();
            var is_first = true;
            while (try files_it.next(io)) |files_entry| {
                if (is_first) {
                    std.log.info("cleaning compiler '{s}'", .{install_entry.name});
                    is_first = false;
                }
                try fixdeletetree.deleteTree(files_dir, io, files_entry.name);
            }
        }
    }
}

const ParsedInstallDir = struct {
    test_name: []const u8,
    hash: []const u8,
    cache_o: []const u8,
};
fn parseInstallDir(install_dir: []const u8) union(enum) {
    good: ParsedInstallDir,
    bad: []const u8,
} {
    {
        const name = std.fs.path.basename(install_dir);
        if (!std.mem.eql(u8, name, "install")) return .{ .bad = "did not end with 'install'" };
    }
    const test_dir = std.fs.path.dirname(install_dir) orelse return .{ .bad = "missing test dir" };
    const test_name = std.fs.path.basename(test_dir);
    const cache_dir = std.fs.path.dirname(test_dir) orelse return .{ .bad = "missing cache/hash dir" };
    const hash = std.fs.path.basename(cache_dir);
    return .{ .good = .{
        .test_name = test_name,
        .hash = hash,
        .cache_o = std.fs.path.dirname(cache_dir) orelse return .{ .bad = "missing cache o dir" },
    } };
}

fn containsCompiler(compilers: []const u8, compiler: []const u8) bool {
    var it = std.mem.splitScalar(u8, compilers, ',');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, compiler)) return true;
    }
    return false;
}

fn isCompilerFilesEntry(path: []const u8) ?[]const u8 {
    var it = std.fs.path.NativeComponentIterator.init(path);
    {
        const name = (it.next() orelse return null).name;
        if (!std.mem.eql(u8, name, "install")) return null;
    }
    const compiler = it.next() orelse return null;
    const leaf = (it.next() orelse return null).name;
    if (!std.mem.eql(u8, leaf, "files")) return null;
    _ = it.next() orelse return null;
    if (null != it.next()) return null;
    return compiler.name;
}

const SharedSiblingState = struct {
    logged: bool = false,
};
fn copyEnvDir(
    io: Io,
    allocator: std.mem.Allocator,
    in_root: []const u8,
    out_root: []const u8,
    in_path: []const u8,
    out_path: []const u8,
    opt: struct { with_compilers: []const u8 },
    shared_sibling_state: *SharedSiblingState,
) !void {
    std.debug.assert(std.mem.startsWith(u8, in_path, in_root));
    std.debug.assert(std.mem.startsWith(u8, out_path, out_root));

    {
        const separators = switch (builtin.os.tag) {
            .windows => "\\/",
            else => "/",
        };
        const relative = std.mem.trimStart(u8, in_path[in_root.len..], separators);
        if (isCompilerFilesEntry(relative)) |compiler| {
            const exclude = !containsCompiler(opt.with_compilers, compiler);
            if (!shared_sibling_state.logged) {
                shared_sibling_state.logged = true;
                std.log.info("{s} compiler '{s}'", .{ if (exclude) "excluding" else "including", compiler });
            }
            if (exclude) return;
        }
    }

    const cwd = Io.Dir.cwd();
    var in_dir = try cwd.openDir(io, in_path, .{ .iterate = true });
    defer in_dir.close(io);

    var it = in_dir.iterate();
    while (try it.next(io)) |entry| {
        const in_sub_path = try std.fs.path.join(allocator, &.{ in_path, entry.name });
        const out_sub_path = try std.fs.path.join(allocator, &.{ out_path, entry.name });
        switch (entry.kind) {
            .directory => {
                try cwd.createDir(io, out_sub_path, .default_dir);
                var shared_child_state: SharedSiblingState = .{};
                try copyEnvDir(io, allocator, in_root, out_root, in_sub_path, out_sub_path, opt, &shared_child_state);
            },
            .file => try cwd.copyFile(in_sub_path, cwd, out_sub_path, io, .{}),
            .sym_link => {
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const in_len = try cwd.readLink(io, in_sub_path, &target_buf);
                const in_target = target_buf[0..in_len];
                var out_target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const out_target = blk: {
                    if (std.fs.path.isAbsolute(in_target)) {
                        if (!std.mem.startsWith(u8, in_target, in_root)) std.debug.panic(
                            "expected symlink target to start with '{s}' but got '{s}'",
                            .{ in_root, in_target },
                        );
                        break :blk try std.fmt.bufPrint(
                            &out_target_buf,
                            "{s}{s}",
                            .{ out_root, in_target[in_root.len..] },
                        );
                    }
                    break :blk in_target;
                };

                if (builtin.os.tag == .windows) @panic(
                    "we got a symlink on windows?",
                ) else try cwd.symLink(io, out_target, out_sub_path, .{});
            },
            else => std.debug.panic("copy {}", .{entry}),
        }
    }
}

// cache-buster
// cache-buster 2
// cache-buster 3
