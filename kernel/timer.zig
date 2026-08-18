// Timer interrupt from the local APIC, 100 times per second.
//
// The APIC is used in x2APIC mode: all registers are MSRs, so no need to map
// the APIC's memory page. The old 8259 PICs get masked so they stay quiet.
// The APIC timer's speed isn't known, so measure it first against the PIT,
// which always runs at 1.193182 MHz.

const std = @import("std");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.timer);

pub const vector = 32;
pub const spurious_vector = 255;
pub const hz = 100;

const APIC_BASE = 0x1b;
const EOI = 0x80b;
const SPURIOUS = 0x80f;
const LVT_TIMER = 0x832;
const TIMER_INITIAL = 0x838;
const TIMER_CURRENT = 0x839;
const TIMER_DIVIDE = 0x83e;
const DIVIDE_BY_16 = 0b0011;

var ticks: u64 = 0;

pub fn init() void {
    // mask both PICs
    cpu.outb(0x21, 0xff);
    cpu.outb(0xa1, 0xff);

    if (!cpu.hasX2apic()) @panic("no x2APIC (QEMU needs -cpu max)");
    // enable the APIC (bit 11) in x2APIC mode (bit 10)
    cpu.wrmsr(APIC_BASE, cpu.rdmsr(APIC_BASE) | (1 << 11) | (1 << 10));
    cpu.wrmsr(SPURIOUS, (1 << 8) | spurious_vector);

    const per_ms = countsPerMs();
    cpu.wrmsr(TIMER_DIVIDE, DIVIDE_BY_16);
    cpu.wrmsr(LVT_TIMER, (1 << 17) | vector); // periodic
    cpu.wrmsr(TIMER_INITIAL, per_ms * (1000 / hz));
    log.info("APIC timer: {d} counts per ms, {d} Hz", .{ per_ms, hz });
}

// Let the APIC timer count down while PIT channel 2 counts 10 ms.
fn countsPerMs() u32 {
    const pit_count: u16 = 1_193_182 / 100; // 10 ms

    // channel 2 gate on (port 0x61 bit 0), speaker off (bit 1)
    cpu.outb(0x61, (cpu.inb(0x61) & 0xfc) | 0x01);
    cpu.outb(0x43, 0b1011_0000); // channel 2, low+high byte, mode 0
    cpu.outb(0x42, @truncate(pit_count));
    cpu.outb(0x42, @truncate(pit_count >> 8));

    cpu.wrmsr(TIMER_DIVIDE, DIVIDE_BY_16);
    cpu.wrmsr(LVT_TIMER, 1 << 16); // masked, just counting
    cpu.wrmsr(TIMER_INITIAL, 0xffff_ffff);
    // restart the PIT count by toggling the gate
    const gate = cpu.inb(0x61);
    cpu.outb(0x61, gate & 0xfe);
    cpu.outb(0x61, gate | 0x01);

    // bit 5 goes high when the PIT is done. Don't wait forever.
    var tries: u32 = 0;
    while (cpu.inb(0x61) & 0x20 == 0) : (tries += 1) {
        if (tries == 100_000_000) @panic("PIT never finished, can't measure the APIC timer");
    }
    const elapsed = 0xffff_ffff - @as(u32, @truncate(cpu.rdmsr(TIMER_CURRENT)));
    cpu.wrmsr(TIMER_INITIAL, 0);
    return elapsed / 10;
}

/// Called from the interrupt handler.
pub fn onTick() void {
    ticks += 1;
    cpu.wrmsr(EOI, 0);
}

pub fn ticksSinceBoot() u64 {
    return @atomicLoad(u64, &ticks, .monotonic);
}
