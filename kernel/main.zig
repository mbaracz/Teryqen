const std = @import("std");
const serial = @import("serial.zig");
const limine = @import("limine.zig");
const fb = @import("fb.zig");

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

    if (limine.framebuffer()) |info| {
        if (fb.init(info)) |screen| {
            screen.clear(screen.rgb(0x1c, 0x1f, 0x26));
            screen.drawText(32, 32, "hello from teryqen!", screen.rgb(0xe6, 0xe8, 0xee), 4);
        } else {
            serial.write("framebuffer is not 32 bpp\n");
        }
    } else {
        serial.write("no framebuffer\n");
    }
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
