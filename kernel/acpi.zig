// ACPI tables, just enough to find the I/O APIC: RSDP -> XSDT (or RSDT on
// old firmware) -> MADT ("APIC"). The MADT lists the I/O APICs and which
// legacy IRQ goes to which interrupt line ("overrides").
//
// The firmware wrote these, so lengths are checked before reading past them.

const std = @import("std");
const limine = @import("limine.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(.acpi);

pub const IoApicInfo = struct { address: u64, gsi_base: u32 };
pub const Override = struct { irq: u8, gsi: u32, active_low: bool, level: bool };

pub var io_apic: ?IoApicInfo = null;
var overrides_buf: [16]Override = undefined;
pub var overrides: []const Override = &.{};

pub fn init() void {
    const rsdp_virt = limine.rsdp() orelse return log.warn("no RSDP from Limine", .{});
    const rsdp = map(rsdp_virt - limine.hhdmOffset().?, 36);
    if (!std.mem.eql(u8, rsdp[0..8], "RSD PTR ")) return log.err("bad RSDP", .{});
    const madt = if (rsdp[15] >= 2)
        findTable(std.mem.readInt(u64, rsdp[24..32], .little), 8, "APIC")
    else
        findTable(std.mem.readInt(u32, rsdp[16..20], .little), 4, "APIC");
    parseMadt(madt orelse return log.err("no MADT", .{}));
}

/// Goes through the XSDT (8 byte entries) or RSDT (4 byte entries).
fn findTable(root_phys: u64, entry_size: usize, signature: []const u8) ?[]const u8 {
    const root = table(root_phys) orelse return null;
    var off: usize = 36;
    while (off + entry_size <= root.len) : (off += entry_size) {
        const phys = if (entry_size == 8) std.mem.readInt(u64, root[off..][0..8], .little) else std.mem.readInt(u32, root[off..][0..4], .little);
        const t = table(phys) orelse continue;
        if (std.mem.eql(u8, t[0..4], signature)) return t;
    }
    return null;
}

/// A table with its header: maps it, checks the length and checksum.
fn table(phys: u64) ?[]const u8 {
    const header = map(phys, 36);
    const len = std.mem.readInt(u32, header[4..8], .little);
    if (len < 36 or len > 1024 * 1024) return null;
    const bytes = map(phys, len);
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    if (sum != 0) return null;
    return bytes;
}

fn parseMadt(madt: []const u8) void {
    var count: usize = 0;
    var off: usize = 44; // header + local APIC address + flags
    while (off + 2 <= madt.len) {
        const kind = madt[off];
        const len = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        const e = madt[off..][0..len];
        switch (kind) {
            1 => if (len >= 12 and io_apic == null) { // I/O APIC (only use the first)
                io_apic = .{
                    .address = std.mem.readInt(u32, e[4..8], .little),
                    .gsi_base = std.mem.readInt(u32, e[8..12], .little),
                };
            },
            2 => if (len >= 10 and count < overrides_buf.len) { // interrupt source override
                const flags = std.mem.readInt(u16, e[8..10], .little);
                overrides_buf[count] = .{
                    .irq = e[3],
                    .gsi = std.mem.readInt(u32, e[4..8], .little),
                    .active_low = flags & 3 == 3,
                    .level = (flags >> 2) & 3 == 3,
                };
                count += 1;
            },
            else => {},
        }
        off += len;
    }
    overrides = overrides_buf[0..count];
    if (io_apic) |a| log.info("I/O APIC at 0x{x}, {d} IRQ overrides", .{ a.address, count });
}

fn map(phys: u64, len: u64) []const u8 {
    return @as([*]const u8, @ptrFromInt(paging.mapPhysical(phys, len, 0)))[0..len];
}
