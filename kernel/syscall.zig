// User mode (ring 3) and system calls.
//
// A user program calls the kernel with the `syscall` instruction:
//   rax = number, rdi/rsi/rdx = arguments, result comes back in rax.
//   0 exit()   1 write(ptr, len)   2 yield()
// The CPU jumps to syscallEntry with the user's rsp still loaded, so the
// entry first switches to the thread's kernel stack.
//
// Every program gets its own address space (paging.newAddressSpace), so they
// can all use the same addresses without seeing each other.

const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const thread = @import("thread.zig");
const serial = @import("serial.zig");
const console = @import("console.zig");
const elf = @import("elf.zig");
const initramfs = @import("initramfs.zig");

const log = std.log.scoped(.syscall);

const EFER = 0xc0000080;
const STAR = 0xc0000081;
const LSTAR = 0xc0000082;
const FMASK = 0xc0000084;

const stack_top: u64 = 0x7fff_ffff_f000;
const stack_pages = 4; // 16 KiB, std.fmt in Debug mode wants quite a bit

// Used by syscallEntry. One CPU, so plain globals are fine.
export var kernel_rsp: u64 = 0; // set on every thread switch
export var user_rsp_scratch: u64 = 0;

pub var console_ready = false;

pub fn init() void {
    cpu.wrmsr(EFER, cpu.rdmsr(EFER) | 1); // SCE: syscall enable
    // kernel CS for syscall at bits 32..47; sysret uses (bits 48..63) + 8 for
    // SS and + 16 for CS, so 0x10 gives user data 0x18 and user code 0x20
    cpu.wrmsr(STAR, (@as(u64, 0x10) << 48) | (@as(u64, gdt.kernel_code) << 32));
    cpu.wrmsr(LSTAR, @intFromPtr(&syscallEntry));
    cpu.wrmsr(FMASK, 1 << 9); // interrupts off while in the kernel
}

/// Called by thread.zig when it switches to a thread with this kernel stack.
pub fn setKernelStack(top: u64) void {
    kernel_rsp = top;
    gdt.setKernelStack(top);
}

export fn syscallEntry() callconv(.naked) void {
    asm volatile (
        \\movq %%rsp, user_rsp_scratch(%%rip)
        \\movq kernel_rsp(%%rip), %%rsp
        // save what we need to go back, on the kernel stack (another thread
        // may do a syscall before we return, so not in a global)
        \\pushq user_rsp_scratch(%%rip)
        \\pushq %%rcx
        \\pushq %%r11
        // don't leak kernel values in the registers the handler is free to change
        \\pushq %%rdi
        \\pushq %%rsi
        \\pushq %%rdx
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\subq $8, %%rsp
        // handleSyscall(number, a, b, c)
        \\movq %%rdx, %%rcx
        \\movq %%rsi, %%rdx
        \\movq %%rdi, %%rsi
        \\movq %%rax, %%rdi
        \\callq handleSyscall
        \\addq $8, %%rsp
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdx
        \\popq %%rsi
        \\popq %%rdi
        \\popq %%r11
        \\popq %%rcx
        \\popq %%rsp
        \\sysretq
    );
}

export fn handleSyscall(number: u64, a: u64, b: u64, c: u64) callconv(.c) u64 {
    _ = c;
    switch (number) {
        0 => {
            log.info("thread {d}: program exited with {d}", .{ thread.currentId(), a });
            endProgram();
        },
        1 => {
            // the pointer comes from the user, it has to point into user memory
            if (a >= 0x8000_0000_0000 or b > 4096 or a + b > 0x8000_0000_0000) return std.math.maxInt(u64);
            const text = @as([*]const u8, @ptrFromInt(a))[0..b];
            serial.write(text);
            if (console_ready) console.write(text);
            return b;
        },
        2 => {
            thread.yield();
            return 0;
        },
        else => return std.math.maxInt(u64),
    }
}

/// Thread entry: load a program from the initramfs into a new address space,
/// give it a stack, then drop to ring 3. `path` points to a []const u8 with
/// the file name.
pub fn runProgram(path: usize) callconv(.c) noreturn {
    const name = @as(*const []const u8, @ptrFromInt(path)).*;
    const space = paging.newAddressSpace();
    thread.setAddressSpace(space);
    const file = initramfs.find(name) orelse {
        log.err("thread {d}: no {s} in the initramfs", .{ thread.currentId(), name });
        endProgram();
    };
    const entry = elf.load(space, file) catch |err| {
        log.err("thread {d}: can't load {s}: {s}", .{ thread.currentId(), name, @errorName(err) });
        endProgram();
    };
    for (1..stack_pages + 1) |i| {
        const frame = pmm.alloc() orelse @panic("no memory for the user stack");
        @memset(pmm.toVirt([4096]u8, frame), 0);
        paging.mapIn(space, stack_top - i * 4096, frame, paging.USER | paging.WRITABLE | paging.NO_EXECUTE);
    }

    log.debug("thread {d}: entering ring 3 at 0x{x}", .{ thread.currentId(), entry });
    // iretq pops rip, cs, rflags, rsp, ss. Interrupts on (0x202) in user mode.
    asm volatile (
        \\pushq %[ss]
        \\pushq %[rsp]
        \\pushq $0x202
        \\pushq %[cs]
        \\pushq %[rip]
        \\iretq
        :
        : [ss] "r" (@as(u64, gdt.user_data)),
          [rsp] "r" (stack_top),
          [cs] "r" (@as(u64, gdt.user_code)),
          [rip] "r" (entry),
    );
    unreachable;
}

/// The program is done (exit or crash): free its whole address space, end
/// the thread.
pub fn endProgram() noreturn {
    const space = thread.addressSpace();
    thread.setAddressSpace(0); // can't free the page tables we're running on
    paging.freeAddressSpace(space);
    thread.exit();
}
