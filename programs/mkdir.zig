// mkdir dir...: makes directories.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var args_buf: [128]u8 = undefined;
    var dirs = std.mem.tokenizeScalar(u8, sys.args(&args_buf), ' ');
    while (dirs.next()) |dir| {
        if (!sys.mkdir(dir)) {
            sys.printf("mkdir: can't make {s}\n", .{dir});
            sys.exit(1);
        }
    }
}
