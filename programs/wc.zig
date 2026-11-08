// wc [file]: counts lines, words and bytes of a file, or of stdin.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var args_buf: [128]u8 = undefined;
    const path = sys.args(&args_buf);
    const fd = if (path.len == 0) sys.stdin else sys.open(path, .read) orelse {
        sys.printf("wc: {s}: not found\n", .{path});
        sys.exit(1);
    };
    var lines: u64 = 0;
    var words: u64 = 0;
    var bytes: u64 = 0;
    var in_word = false;
    var buf: [512]u8 = undefined;
    while (true) {
        const n = sys.read(fd, &buf) orelse break;
        if (n == 0) break;
        for (buf[0..n]) |c| {
            if (c == '\n') lines += 1;
            if (c == ' ' or c == '\n' or c == '\t') {
                in_word = false;
            } else if (!in_word) {
                in_word = true;
                words += 1;
            }
        }
        bytes += n;
    }
    sys.printf("{d} {d} {d}\n", .{ lines, words, bytes });
}
