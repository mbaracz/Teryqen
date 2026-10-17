// Small x86 instructions that several files need.

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return @as(u64, high) << 32 | low;
}

pub fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

/// CPUID leaf 1, ECX bit 21
pub fn hasX2apic() bool {
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [ecx] "={ecx}" (ecx),
        : [leaf] "{eax}" (@as(u32, 1)),
          [sub] "{ecx}" (@as(u32, 0)),
        : .{ .ebx = true, .edx = true });
    return ecx & (1 << 21) != 0;
}

/// Turns interrupts off and returns whether they were on before, so
/// restoreInterrupts() can put things back the way they were.
pub fn disableInterrupts() bool {
    const flags = asm volatile (
        \\pushfq
        \\popq %[flags]
        \\cli
        : [flags] "=r" (-> u64),
        :
        : .{ .memory = true });
    return flags & (1 << 9) != 0; // IF
}

pub fn restoreInterrupts(were_on: bool) void {
    if (were_on) asm volatile ("sti" ::: .{ .memory = true });
}

pub fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[value]"
        : [value] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

pub fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[value]"
        : [value] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}
