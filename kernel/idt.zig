// IDT for the 32 CPU exceptions (+ the timer interrupt). Before this, any exception (bad pointer,
// ud2...) made QEMU triple fault and reboot without saying anything.
//
// Every vector gets a small stub (generated at comptime) that pushes a fake
// error code if the CPU didn't push one, then the vector number, and jumps to
// interruptCommon. That one saves all registers and calls handle() with them.

const std = @import("std");
const gdt = @import("gdt.zig");
const timer = @import("timer.zig");
const syscall = @import("syscall.zig");

const log = std.log.scoped(.cpu);

const names = [32][]const u8{
    "divide error",   "debug",               "NMI",            "breakpoint",
    "overflow",       "bound range",         "invalid opcode", "device not available",
    "double fault",   "coprocessor overrun", "invalid TSS",    "segment not present",
    "stack fault",    "general protection",  "page fault",     "reserved",
    "x87 fpu error",  "alignment check",     "machine check",  "simd fpu error",
    "virtualization", "control protection",  "reserved",       "reserved",
    "reserved",       "reserved",            "reserved",       "reserved",
    "hypervisor",     "vmm communication",   "security",       "reserved",
};

// The CPU pushes an error code only for these
fn hasErrorCode(vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

// What's on the stack when handle() gets called, lowest address first
pub const Frame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    // pushed by the CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const Gate = packed struct(u128) {
    offset_low: u16,
    selector: u16,
    ist: u3 = 0,
    _reserved0: u5 = 0,
    type: u4 = 0b1110, // interrupt gate
    _zero: bool = false,
    privilege: u2 = 0,
    present: bool = true,
    offset_high: u48,
    _reserved1: u32 = 0,
};

var idt: [256]Gate = undefined;

const Pointer = packed struct(u80) { limit: u16, base: u64 };

pub fn init() void {
    @memset(std.mem.asBytes(&idt), 0);
    inline for (0..32) |vector| setGate(vector, @intFromPtr(&stub(vector)));
    setGate(timer.vector, @intFromPtr(&stub(timer.vector)));
    setGate(timer.spurious_vector, @intFromPtr(&stub(timer.spurious_vector)));
    const ptr = Pointer{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&ptr),
        : .{ .memory = true });
}

fn setGate(vector: u8, addr: u64) void {
    idt[vector] = .{
        .offset_low = @truncate(addr),
        .offset_high = @truncate(addr >> 16),
        .selector = gdt.kernel_code,
    };
}

fn stub(comptime vector: u8) fn () callconv(.naked) void {
    return struct {
        fn entry() callconv(.naked) void {
            asm volatile ((if (hasErrorCode(vector)) "" else "pushq $0\n") ++
                    std.fmt.comptimePrint("pushq ${d}\n", .{vector}) ++
                    "jmp interruptCommon");
        }
    }.entry;
}

export fn interruptCommon() callconv(.naked) void {
    asm volatile (
        \\pushq %%rax
        \\pushq %%rbx
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%rbp
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\movq %%rsp, %%rdi
        \\cld
        \\callq handleException
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rbp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\addq $16, %%rsp
        \\iretq
    );
}

export fn handleException(frame: *Frame) callconv(.c) void {
    switch (frame.vector) {
        timer.vector => return timer.onTick(),
        // spurious interrupt from the APIC, nothing to do (and no EOI)
        timer.spurious_vector => return,
        // breakpoint (int3) is harmless, just continue after it
        3 => return,
        else => {},
    }
    if (frame.cs & 3 == 3) {
        // a user program crashed, that's its problem, not the kernel's
        log.err("user program: exception {d} ({s}) at rip 0x{x}, killing it", .{ frame.vector, names[frame.vector], frame.rip });
        syscall.endProgram(255);
    }
    dumpRegisters(frame);
    std.debug.panic("exception {d} ({s}), error code 0x{x}", .{
        frame.vector, names[frame.vector], frame.error_code,
    });
}

fn dumpRegisters(f: *const Frame) void {
    if (f.vector == 14) {
        // page fault: cr2 has the address that was accessed
        const cr2 = asm volatile ("movq %%cr2, %[out]"
            : [out] "=r" (-> u64),
        );
        const what = if (f.error_code & 0x10 != 0) "executing" else if (f.error_code & 0x2 != 0) "writing" else "reading";
        const why = if (f.error_code & 0x1 != 0) "page protection" else "page not mapped";
        log.err("page fault {s} 0x{x}: {s}", .{ what, cr2, why });
    }
    log.err("rip {x:0>16} rsp {x:0>16} rflags {x}", .{ f.rip, f.rsp, f.rflags });
    log.err("rax {x:0>16} rbx {x:0>16} rcx {x:0>16} rdx {x:0>16}", .{ f.rax, f.rbx, f.rcx, f.rdx });
    log.err("rsi {x:0>16} rdi {x:0>16} rbp {x:0>16} r8  {x:0>16}", .{ f.rsi, f.rdi, f.rbp, f.r8 });
    log.err("r9  {x:0>16} r10 {x:0>16} r11 {x:0>16} r12 {x:0>16}", .{ f.r9, f.r10, f.r11, f.r12 });
    log.err("r13 {x:0>16} r14 {x:0>16} r15 {x:0>16}", .{ f.r13, f.r14, f.r15 });
}
