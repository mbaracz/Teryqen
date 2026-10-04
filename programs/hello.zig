// First real user program.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    for (1..4) |i| {
        sys.printf("Hello from hello.elf! ({d})\n", .{i});
        sys.yield();
    }
}
