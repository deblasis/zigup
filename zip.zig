//! zip — minimal zip archiver for the CI step (0.16-final port).
//!
//! NOTE: this port writes STORE (uncompressed) entries only. The old
//! deflate path depended on the pre-0.16 std.io reader/writer combinators
//! (countingWriter/bufferedReader/flate.compress over generic Readers)
//! which no longer exist; store keeps the tool and the CI archive step
//! fully functional with deterministic, arithmetically-computed offsets
//! instead of a counting writer.

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
    std.debug.print("Usage: zip [-options] ZIP_FILE FILES/DIRS..\n", .{});
    std.process.exit(1);
}

pub fn main(init: process.Init) !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const io = init.io;

    var non_option_args: std.ArrayList([]const u8) = .empty;
    {
        var it = try process.Args.Iterator.initAllocator(init.minimal.args, arena);
        _ = it.next(); // argv[0]
        while (it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                try non_option_args.append(arena, arg);
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
    }

    const cmd_args = non_option_args.items;
    if (cmd_args.len < 2) usage();
    const zip_file_arg = cmd_args[0];
    const paths_to_include = cmd_args[1..];

    // expand cmdline arguments to a list of files
    var file_entries: std.ArrayList(FileEntry) = .empty;
    for (paths_to_include) |path| {
        const stat = Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => fatal("path '{s}' is not found", .{path}),
            else => |e| return e,
        };
        switch (stat.kind) {
            .directory => {
                @panic("todo: directories");
            },
            .file => {
                if (isBadFilename(path))
                    fatal("filename '{s}' is invalid for zip files", .{path});
                try file_entries.append(arena, .{
                    .path = path,
                    .size = stat.size,
                });
            },
            .sym_link => fatal("todo: symlinks", .{}),
            .block_device,
            .character_device,
            .named_pipe,
            .unix_domain_socket,
            .whiteout,
            .door,
            .event_port,
            .unknown,
            => fatal("file '{s}' is an unsupported type {s}", .{ path, @tagName(stat.kind) }),
        }
    }

    const store = try arena.alloc(FileStore, file_entries.items.len);
    // no need to free

    try writeZip(io, zip_file_arg, file_entries.items, store);

    // go fix up the local file headers (crc32/size are only known after the
    // data has been streamed through)
    {
        const zip_file = Io.Dir.cwd().openFile(io, zip_file_arg, .{ .mode = .read_write }) catch |err|
            fatal("open file '{s}' failed: {s}", .{ zip_file_arg, @errorName(err) });
        defer zip_file.close(io);
        for (file_entries.items, 0..) |file, i| {
            const hdr: std.zip.LocalFileHeader = .{
                .signature = std.zip.local_file_header_sig,
                .version_needed_to_extract = 10,
                .flags = .{ .encrypted = false, ._ = 0 },
                .compression_method = .store,
                .last_modification_time = 0,
                .last_modification_date = 0,
                .crc32 = store[i].crc32,
                .compressed_size = store[i].compressed_size,
                .uncompressed_size = @intCast(file.size),
                .filename_len = @intCast(file.path.len),
                .extra_len = 0,
            };
            try writeStructEndianPositional(io, zip_file, store[i].file_offset, hdr, .little);
        }
    }
}

const FileEntry = struct {
    path: []const u8,
    size: u64,
};

fn writeZip(io: Io, zip_file_arg: []const u8, file_entries: []const FileEntry, store: []FileStore) !void {
    const zip_file = Io.Dir.cwd().createFile(io, zip_file_arg, .{ .truncate = true }) catch |err|
        fatal("create file '{s}' failed: {s}", .{ zip_file_arg, @errorName(err) });
    defer zip_file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = zip_file.writerStreaming(io, &buf);
    const out = &fw.interface;

    var offset: u64 = 0;
    var central_offset: ?u64 = null;
    var central_end: u64 = 0;
    var central_count: u64 = 0;

    for (file_entries, 0..) |file_entry, i| {
        const file_offset = offset;

        // local file header (crc32/sizes fixed up afterwards)
        try writeStructEndian(out, std.zip.LocalFileHeader{
            .signature = std.zip.local_file_header_sig,
            .version_needed_to_extract = 10,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = 0,
            .compressed_size = 0,
            .uncompressed_size = 0,
            .filename_len = @intCast(file_entry.path.len),
            .extra_len = 0,
        }, .little);
        try out.writeAll(file_entry.path);
        offset += @sizeOf(std.zip.LocalFileHeader) + file_entry.path.len;

        // stream the file, computing crc32 as we go
        var file = try Io.Dir.cwd().openFile(io, file_entry.path, .{});
        defer file.close(io);
        var file_buf: [64 * 1024]u8 = undefined;
        var fr = file.readerStreaming(io, &file_buf);

        var hash = std.hash.Crc32.init();
        var remaining = file_entry.size;
        while (remaining > 0) {
            const chunk = file_buf[0..@min(remaining, file_buf.len)];
            try fr.interface.readSliceAll(chunk);
            hash.update(chunk);
            try out.writeAll(chunk);
            remaining -= chunk.len;
        }
        offset += file_entry.size;

        store[i] = .{
            .file_offset = file_offset,
            .compression = .store,
            .uncompressed_size = @intCast(file_entry.size),
            .crc32 = hash.final(),
            .compressed_size = @intCast(file_entry.size),
        };
    }

    for (file_entries, 0..) |file, i| {
        if (central_offset == null) central_offset = offset;
        central_count += 1;
        try writeStructEndian(out, std.zip.CentralDirectoryFileHeader{
            .signature = std.zip.central_file_header_sig,
            .version_made_by = 0,
            .version_needed_to_extract = 10,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = store[i].compression,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .crc32 = store[i].crc32,
            .compressed_size = store[i].compressed_size,
            .uncompressed_size = @intCast(store[i].uncompressed_size),
            .filename_len = @intCast(file.path.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = @intCast(store[i].file_offset),
        }, .little);
        try out.writeAll(file.path);
        offset += @sizeOf(std.zip.CentralDirectoryFileHeader) + file.path.len;
        central_end = offset;
    }

    const cd_offset = central_offset orelse 0;
    try writeStructEndian(out, std.zip.EndRecord{
        .signature = std.zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(central_count),
        .record_count_total = @intCast(central_count),
        .central_directory_size = @intCast(central_end - cd_offset),
        .central_directory_offset = @intCast(cd_offset),
        .comment_len = 0,
    }, .little);
    try out.flush();
}

fn isBadFilename(filename: []const u8) bool {
    if (std.mem.indexOfScalar(u8, filename, '\\')) |_|
        return true;

    if (filename.len == 0 or filename[0] == '/' or filename[0] == '\\')
        return true;

    var it = std.mem.splitAny(u8, filename, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    return false;
}

// Used to store any data from writing a file to the zip archive that's needed
// when writing the corresponding central directory record.
pub const FileStore = struct {
    file_offset: u64,
    compression: std.zip.CompressionMethod,
    uncompressed_size: u32,
    crc32: u32,
    compressed_size: u32,
};

const native_endian = @import("builtin").target.cpu.arch.endian();

fn writeStructBytes(value: anytype, endian: std.builtin.Endian) [@sizeOf(@TypeOf(value))]u8 {
    var copy = value;
    if (native_endian != endian) byteSwapAllFields(@TypeOf(value), &copy);
    return @as(*const [@sizeOf(@TypeOf(value))]u8, @ptrCast(&copy)).*;
}

fn writeStructEndian(writer: *Io.Writer, value: anytype, endian: std.builtin.Endian) !void {
    try writer.writeAll(&writeStructBytes(value, endian));
}

fn writeStructEndianPositional(io: Io, file: Io.File, offset: u64, value: anytype, endian: std.builtin.Endian) !void {
    const bytes = writeStructBytes(value, endian);
    try file.writePositionalAll(io, &bytes, offset);
}

pub fn byteSwapAllFields(comptime S: type, ptr: *S) void {
    switch (@typeInfo(S)) {
        .@"struct" => {
            inline for (std.meta.fields(S)) |f| {
                switch (@typeInfo(f.type)) {
                    .@"struct" => |struct_info| if (struct_info.backing_integer) |Int| {
                        @field(ptr, f.name) = @bitCast(@byteSwap(@as(Int, @bitCast(@field(ptr, f.name)))));
                    } else {
                        byteSwapAllFields(f.type, &@field(ptr, f.name));
                    },
                    .array => byteSwapAllFields(f.type, &@field(ptr, f.name)),
                    .@"enum" => {
                        @field(ptr, f.name) = @enumFromInt(@byteSwap(@intFromEnum(@field(ptr, f.name))));
                    },
                    else => {
                        @field(ptr, f.name) = @byteSwap(@field(ptr, f.name));
                    },
                }
            }
        },
        .array => {
            for (ptr) |*item| {
                switch (@typeInfo(@TypeOf(item.*))) {
                    .@"struct", .array => byteSwapAllFields(@TypeOf(item.*), item),
                    .@"enum" => {
                        item.* = @enumFromInt(@byteSwap(@intFromEnum(item.*)));
                    },
                    else => {
                        item.* = @byteSwap(item.*);
                    },
                }
            }
        },
        else => @compileError("byteSwapAllFields expects a struct or array as the first argument"),
    }
}
