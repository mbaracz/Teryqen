// ls [directory]: what's in a directory (the root if none given).

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var args_buf: [128]u8 = undefined;
    const args = sys.args(&args_buf);
    const path = if (args.len == 0) "/" else args;
    const fd = sys.open(path, .read) orelse {
        sys.printf("ls: {s}: not found\n", .{path});
        sys.exit(1);
    };
    defer sys.close(fd);
    var buf: [2048]u8 = undefined;
    const n = sys.readdir(fd, &buf) orelse {
        sys.printf("ls: {s}: not a directory\n", .{path});
        sys.exit(1);
    };
    sys.print(buf[0..n]);
}
