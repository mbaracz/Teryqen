// cat [file...]: prints files, or stdin if there are none (cat in a pipe).

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var args_buf: [128]u8 = undefined;
    const args = sys.args(&args_buf);
    if (args.len == 0) return copy(sys.stdin, "stdin");
    var files = std.mem.tokenizeScalar(u8, args, ' ');
    while (files.next()) |path| {
        const fd = sys.open(path, .read) orelse {
            sys.printf("cat: {s}: not found\n", .{path});
            sys.exit(1);
        };
        defer sys.close(fd);
        copy(fd, path);
    }
}

fn copy(fd: u64, name: []const u8) void {
    var buf: [512]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) orelse {
            sys.printf("cat: {s}: can't read it\n", .{name});
            sys.exit(1);
        };
        if (n == 0) break;
        sys.print(buf[0..n]);
    }
}
