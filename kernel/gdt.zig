// GDT. In 64-bit mode segments barely matter, but the CPU still wants
// a valid GDT and I don't want to depend on the one Limine left behind.
// Kernel code/data, user code/data (ring 3) and the TSS.
//
// The order is what syscall/sysret want: sysret takes the user data
// segment at 0x18 and user code at 0x20 (see syscall.zig).

pub const kernel_code: u16 = 0x08;
pub const kernel_data: u16 = 0x10;
pub const user_data: u16 = 0x18 | 3; // | 3 = ring 3
pub const user_code: u16 = 0x20 | 3;
const tss_selector: u16 = 0x28;

// The TSS is only used for one thing in 64-bit mode: rsp0, the stack the CPU
// switches to when an interrupt comes while running in ring 3.
const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    ist: [7]u64 align(1) = @splat(0),
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    iomap_base: u16 align(1) = @sizeOf(Tss), // no I/O bitmap
};

var tss: Tss = .{};

// Standard flat descriptors (values from the OSDev wiki). The TSS takes two
// slots, filled in by init() because it needs the TSS address.
var gdt = [_]u64{
    0,
    0x00af9b000000ffff, // kernel code, 64-bit
    0x00cf93000000ffff, // kernel data
    0x00cff3000000ffff, // user data
    0x00affb000000ffff, // user code, 64-bit
    0, // TSS low
    0, // TSS high
};

const Pointer = packed struct(u80) { limit: u16, base: u64 };

pub fn init() void {
    const base = @intFromPtr(&tss);
    const limit: u64 = @sizeOf(Tss) - 1;
    gdt[5] = (limit & 0xffff) | ((base & 0xffffff) << 16) | (0x89 << 40) | (((base >> 24) & 0xff) << 56);
    gdt[6] = base >> 32;

    const ptr = Pointer{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    // Load it, then reload all segment registers. CS can't be moved into
    // directly, so push the new CS + return address and do a far return.
    asm volatile (
        \\lgdt (%[ptr])
        \\movw %[data], %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        \\xorw %%ax, %%ax
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        \\pushq %[code]
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\ltr %[tss]
        :
        : [ptr] "r" (&ptr),
          [data] "i" (kernel_data),
          [code] "i" (@as(u64, kernel_code)),
          [tss] "r" (tss_selector),
        : .{ .rax = true, .memory = true });
}

/// Stack for interrupts that arrive while in ring 3.
pub fn setKernelStack(top: u64) void {
    tss.rsp0 = top;
}
