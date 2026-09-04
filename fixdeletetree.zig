const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;

//
// TODO: we should fix std library to address these issues
//
pub fn deleteTree(dir: Io.Dir, io: Io, sub_path: []const u8) !void {
    if (builtin.os.tag != .windows) {
        return dir.deleteTree(io, sub_path);
    }

    // workaround issue on windows where it just doesn't delete things
    const MAX_ATTEMPTS = 10;
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        if (dir.deleteTree(io, sub_path)) {
            return;
        } else |err| {
            if (attempt == MAX_ATTEMPTS) return err;
            switch (err) {
                error.FileBusy => {
                    std.log.warn("path '{s}' is busy (attempt {d}), will retry", .{ sub_path, attempt });
                    Io.sleep(io, Io.Duration.fromMilliseconds(100), .monotonic) catch {};
                },
                else => |e| return e,
            }
        }
    }
}

pub fn deleteTreeAbsolute(io: Io, dir_absolute: []const u8) !void {
    std.debug.assert(std.fs.path.isAbsolute(dir_absolute));
    // The cwd handle accepts absolute paths.
    return deleteTree(Io.Dir.cwd(), io, dir_absolute);
}
