const std = @import("std");
const serial = @import("serial.zig");
const limine = @import("limine.zig");

// Limine jumps here in 64-bit mode with interrupts off.
// Clear rbp (end of the stack trace), align the stack and call kmain.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\xorl %%ebp, %%ebp
        \\andq $-16, %%rsp
        \\callq kmain
        \\ud2
    );
}

export fn kmain() noreturn {
    serial.init();
    if (!limine.supported()) {
        serial.write("bootloader too old?\n");
        hang();
    }
    serial.write("hello from teryqen!\n");
    hang();
}

fn hang() noreturn {
    while (true) {
        asm volatile (
            \\cli
            \\hlt
        );
    }
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    serial.write("PANIC: ");
    serial.write(msg);
    serial.write("\n");
    hang();
}

pub const panic = std.debug.FullPanic(panicHandler);
