// I/O APIC: where device interrupts (keyboard, disks...) come in and get sent
// to a CPU with some vector. Two registers: write the register number to
// +0x00, then read/write its value at +0x10. Each interrupt line has a 64-bit
// "redirection entry" at 0x10 + 2*line.

const std = @import("std");
const acpi = @import("acpi.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(.ioapic);

var base: u64 = 0;
var gsi_base: u32 = 0;
var lines: u32 = 0;

const MASKED: u32 = 1 << 16;

pub fn init() bool {
    const info = acpi.io_apic orelse {
        log.err("no I/O APIC, no device interrupts", .{});
        return false;
    };
    base = paging.mapPhysical(info.address, 0x20, paging.NO_CACHE);
    gsi_base = info.gsi_base;
    lines = ((read(0x01) >> 16) & 0xff) + 1;
    // everything off until a driver asks for its line
    for (0..lines) |i| {
        write(@intCast(0x10 + 2 * i), MASKED);
        write(@intCast(0x11 + 2 * i), 0);
    }
    log.info("{d} interrupt lines, all masked", .{lines});
    return true;
}

/// Sends legacy IRQ `irq` (like 1 for the keyboard) to this CPU as `vector`.
pub fn route(irq: u8, vector: u8) void {
    var gsi: u32 = irq;
    var active_low = false;
    var level = false;
    for (acpi.overrides) |o| {
        if (o.irq != irq) continue;
        gsi = o.gsi;
        active_low = o.active_low;
        level = o.level;
    }
    if (base == 0 or gsi < gsi_base or gsi - gsi_base >= lines) return log.err("can't route IRQ {d}", .{irq});
    const line = gsi - gsi_base;
    var low: u32 = vector; // fixed delivery, physical destination
    if (active_low) low |= 1 << 13;
    if (level) low |= 1 << 15;
    write(@intCast(0x11 + 2 * line), 0); // destination: APIC id 0, the only CPU
    write(@intCast(0x10 + 2 * line), low);
    log.debug("IRQ {d} -> line {d} -> vector {d}", .{ irq, line, vector });
}

fn read(reg: u32) u32 {
    @as(*volatile u32, @ptrFromInt(base)).* = reg;
    return @as(*volatile u32, @ptrFromInt(base + 0x10)).*;
}

fn write(reg: u32, value: u32) void {
    @as(*volatile u32, @ptrFromInt(base)).* = reg;
    @as(*volatile u32, @ptrFromInt(base + 0x10)).* = value;
}
