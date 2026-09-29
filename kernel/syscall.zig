// User mode (ring 3) and system calls.
//
// A user program calls the kernel with the `syscall` instruction:
//   rax = number, rdi/rsi/rdx = arguments, result comes back in rax.
//   0 exit(code)         1 write(ptr, len)     2 yield()
//   3 read(ptr, len)     4 spawn(ptr, len)     5 wait(pid)
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

const failed = std.math.maxInt(u64);

export fn handleSyscall(number: u64, a: u64, b: u64, c: u64) callconv(.c) u64 {
    _ = c;
    switch (number) {
        0 => {
            log.debug("thread {d}: program exited with {d}", .{ thread.currentId(), a });
            endProgram(a);
        },
        1 => {
            const text = userSlice(a, b) orelse return failed;
            serial.write(text);
            if (console_ready) console.write(text);
            return b;
        },
        2 => {
            thread.yield();
            return 0;
        },
        3 => {
            // waits until at least one key was typed
            const buf = userSlice(a, b) orelse return failed;
            if (buf.len == 0) return 0;
            // interrupts are off in here, so nothing can sneak in between
            // the check and the sleep
            while (input_len == 0) thread.sleepOn(&input_waiters);
            const n = @min(buf.len, input_len);
            @memcpy(buf[0..n], input[0..n]);
            std.mem.copyForwards(u8, input[0 .. input_len - n], input[n..input_len]);
            input_len -= n;
            return n;
        },
        4 => {
            const name = userSlice(a, b) orelse return failed;
            return spawn(name) orelse failed;
        },
        5 => {
            if (a >= processes.len or !processes[a].used) return failed;
            while (!processes[a].done) thread.sleepOn(&processes[a].waiters);
            const code = processes[a].exit_code;
            processes[a].used = false;
            return code;
        },
        else => return failed,
    }
}

/// The pointer comes from the user, it has to point into user memory.
fn userSlice(ptr: u64, len: u64) ?[]u8 {
    if (ptr >= user_end or len > 4096 or ptr + len > user_end) return null;
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}

const user_end: u64 = 0x8000_0000_0000;

// Keys typed, waiting for someone to read() them.
var input: [256]u8 = undefined;
var input_len: usize = 0;
var input_waiters: thread.WaitQueue = .{};

/// Called by the keyboard thread for every character.
pub fn keyTyped(ch: u8) void {
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    if (input_len < input.len) {
        input[input_len] = ch;
        input_len += 1;
    }
    thread.wakeAll(&input_waiters);
}

// Running programs. The pid is just the index here.
const Process = struct {
    used: bool = false,
    done: bool = false,
    exit_code: u64 = 0,
    waiters: thread.WaitQueue = .{}, // threads in wait() for this one
    name: [64]u8 = undefined,
    name_len: usize = 0,
};
var processes: [16]Process = @splat(.{});

/// Starts the program `name` from the initramfs. Returns its pid.
pub fn spawn(name: []const u8) ?u64 {
    if (name.len > 64 or initramfs.find(name) == null) return null;
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    for (&processes, 0..) |*p, pid| {
        if (p.used) continue;
        // copy the name: the caller's memory isn't visible from the new thread
        p.* = .{ .used = true, .name_len = name.len };
        @memcpy(p.name[0..name.len], name);
        _ = thread.spawn(runProgram, @intFromPtr(p)) catch {
            p.used = false;
            return null;
        };
        return pid;
    }
    return null; // table full
}

/// Thread entry: load a program from the initramfs into a new address space,
/// give it a stack, then drop to ring 3. `arg` is its *Process.
fn runProgram(arg: usize) callconv(.c) noreturn {
    const process: *Process = @ptrFromInt(arg);
    thread.setProcess(arg);
    const name = process.name[0..process.name_len];
    const space = paging.newAddressSpace();
    thread.setAddressSpace(space);
    const file = initramfs.find(name) orelse {
        log.err("thread {d}: no {s} in the initramfs", .{ thread.currentId(), name });
        endProgram(failed);
    };
    const entry = elf.load(space, file) catch |err| {
        log.err("thread {d}: can't load {s}: {s}", .{ thread.currentId(), name, @errorName(err) });
        endProgram(failed);
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
pub fn endProgram(code: u64) noreturn {
    if (thread.process() != 0) {
        const p: *Process = @ptrFromInt(thread.process());
        p.exit_code = code;
        p.done = true;
        thread.wakeAll(&p.waiters);
    }
    const space = thread.addressSpace();
    thread.setAddressSpace(0); // can't free the page tables we're running on
    paging.freeAddressSpace(space);
    thread.exit();
}
