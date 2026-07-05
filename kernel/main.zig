const std = @import("std");

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
    // nothing to do yet
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

// TODO: print the message once there's a serial driver
fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = msg;
    _ = first_trace_addr;
    hang();
}

pub const panic = std.debug.FullPanic(panicHandler);
