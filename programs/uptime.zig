// uptime: how long since boot.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    const total = sys.uptime() / 1000;
    sys.printf("up {d}:{d:0>2}:{d:0>2}\n", .{ total / 3600, total / 60 % 60, total % 60 });
}
