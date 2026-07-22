const std = @import("std");
const serial = @import("serial.zig");
const limine = @import("limine.zig");
const fb = @import("fb.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");

pub const std_options: std.Options = .{
    .logFn = @import("log.zig").logFn,
};

const log = std.log.scoped(.boot);

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
    gdt.init();
    idt.init();
    if (!limine.supported()) {
        log.err("bootloader doesn't support Limine base revision 6", .{});
        hang();
    }
    serial.write("hello from teryqen!\n");

    // check that interrupts come back: int3 should land in the handler and return
    asm volatile ("int3");
    log.debug("survived int3", .{});

    if (limine.framebuffer()) |info| {
        log.info("framebuffer {d}x{d}", .{ info.width, info.height });
        if (fb.init(info)) |screen| {
            screen.clear(screen.rgb(0x1c, 0x1f, 0x26));
            screen.drawText(32, 32, "hello from teryqen!", screen.rgb(0xe6, 0xe8, 0xee), 4);
        } else {
            log.err("framebuffer is {d} bpp, only 32 works", .{info.bpp});
        }
    } else {
        log.warn("no framebuffer", .{});
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
