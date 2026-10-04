// cat file...: prints files.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var args_buf: [128]u8 = undefined;
    var files = std.mem.tokenizeScalar(u8, sys.args(&args_buf), ' ');
    while (files.next()) |path| {
        const fd = sys.open(path, .read) orelse {
            sys.printf("cat: {s}: not found\n", .{path});
            sys.exit(1);
        };
        defer sys.close(fd);
        var buf: [512]u8 = undefined;
        while (true) {
            const n = sys.read(fd, &buf) orelse {
                sys.printf("cat: {s}: can't read it\n", .{path});
                sys.exit(1);
            };
            if (n == 0) break;
            sys.print(buf[0..n]);
        }
    }
}
