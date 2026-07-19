// GDT. In 64-bit mode segments barely matter, but the CPU still wants
// a valid GDT and I don't want to depend on the one Limine left behind.
// Just null + kernel code + kernel data for now. User segments and a TSS
// can come when there's user mode.

pub const kernel_code: u16 = 0x08;
pub const kernel_data: u16 = 0x10;

// Standard flat descriptors (values from the OSDev wiki).
var gdt = [_]u64{
    0,
    0x00af9b000000ffff, // kernel code, 64-bit
    0x00cf93000000ffff, // kernel data
};

const Pointer = packed struct(u80) { limit: u16, base: u64 };

pub fn init() void {
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
        :
        : [ptr] "r" (&ptr),
          [data] "i" (kernel_data),
          [code] "i" (@as(u64, kernel_code)),
        : .{ .rax = true, .memory = true });
}
