// First real user program, loaded by the kernel from an ELF file.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    for (1..4) |i| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Hello from hello.elf! ({d})\n", .{i}) catch unreachable;
        sys.write(text);
        sys.yield();
    }
}
