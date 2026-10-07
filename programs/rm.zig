// rm path...: removes files and empty directories.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var args_buf: [128]u8 = undefined;
    var paths = std.mem.tokenizeScalar(u8, sys.args(&args_buf), ' ');
    while (paths.next()) |path| {
        if (!sys.remove(path)) {
            sys.printf("rm: can't remove {s} (not there, not empty, or in use)\n", .{path});
            sys.exit(1);
        }
    }
}
