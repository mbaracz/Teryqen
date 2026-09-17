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

const log = std.log.scoped(.syscall);

const EFER = 0xc0000080;
const STAR = 0xc0000081;
const LSTAR = 0xc0000082;
const FMASK = 0xc0000084;

const code_address: u64 = 0x40_0000;
const stack_address: u64 = 0x7fff_ffff_e000; // one page, grows down from 0x7fff_ffff_f000

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

// The test program. It's position independent (only rip-relative stuff), so
// its bytes can just be copied to the user page.
comptime {
    asm (
        \\.section .text
        \\.global user_program_start
        \\.global user_program_end
        \\user_program_start:
        \\    movq $3, %r12
        \\1:
        \\    movl $1, %eax
        \\    leaq .Luser_msg(%rip), %rdi
        \\    movl $(.Luser_msg_end - .Luser_msg), %esi
        \\    syscall
        // put the counter on the stack, let the other programs run, check it's
        // still there: same address in every program, but not the same memory
        \\    movq %r12, -8(%rsp)
        \\    movl $2, %eax
        \\    syscall
        \\    cmpq %r12, -8(%rsp)
        \\    jne 2f
        \\    decq %r12
        \\    jnz 1b
        \\    movl $0, %eax
        \\    xorl %edi, %edi
        \\    syscall
        \\2:
        \\    movl $0, %eax
        \\    movl $1, %edi
        \\    syscall
        \\.Luser_msg:
        \\    .ascii "Hello from ring 3!\n"
        \\.Luser_msg_end:
        \\user_program_end:
    );
}

extern const user_program_start: u8;
extern const user_program_end: u8;

/// Thread entry: map the test program and its stack, then drop to ring 3.
pub fn runProgram(_: usize) callconv(.c) noreturn {
    const code = @as([*]const u8, @ptrCast(&user_program_start))[0 .. @intFromPtr(&user_program_end) - @intFromPtr(&user_program_start)];

    const space = paging.newAddressSpace();
    thread.setAddressSpace(space);
    const code_frame = pmm.alloc() orelse @panic("no memory for the user program");
    @memcpy(pmm.toVirt([4096]u8, code_frame)[0..code.len], code);
    paging.mapIn(space, code_address, code_frame, paging.USER); // read + execute
    const stack_frame = pmm.alloc() orelse @panic("no memory for the user stack");
    paging.mapIn(space, stack_address, stack_frame, paging.USER | paging.WRITABLE | paging.NO_EXECUTE);

    log.debug("thread {d}: entering ring 3", .{thread.currentId()});
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
          [rsp] "r" (stack_address + 4096),
          [cs] "r" (@as(u64, gdt.user_code)),
          [rip] "r" (code_address),
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
