// PCI: finding devices. The old way through I/O ports 0xcf8/0xcfc
// ("configuration mechanism #1"), enough for QEMU.

const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const outl = cpu.outl;
const inl = cpu.inl;

pub const Device = struct {
    bus: u8,
    slot: u8,
    func: u8,

    fn address(d: Device, offset: u8) u32 {
        return (1 << 31) | (@as(u32, d.bus) << 16) | (@as(u32, d.slot) << 11) |
            (@as(u32, d.func) << 8) | (offset & 0xfc);
    }

    pub fn read32(d: Device, offset: u8) u32 {
        outl(0xcf8, d.address(offset));
        return inl(0xcfc);
    }

    pub fn write32(d: Device, offset: u8, value: u32) void {
        outl(0xcf8, d.address(offset));
        outl(0xcfc, value);
    }

    pub fn vendor(d: Device) u16 {
        return @truncate(d.read32(0));
    }

    pub fn deviceId(d: Device) u16 {
        return @truncate(d.read32(0) >> 16);
    }

    pub fn bar(d: Device, n: u8) u32 {
        return d.read32(0x10 + 4 * n);
    }

    /// Offset of the capability with this id in config space, if it has one.
    pub fn capability(d: Device, id: u8) ?u8 {
        if ((d.read32(0x04) >> 16) & (1 << 4) == 0) return null; // no capability list
        var off: u8 = @truncate(d.read32(0x34) & 0xfc);
        var hops: u8 = 0;
        while (off != 0 and hops < 48) : (hops += 1) {
            const header = d.read32(off);
            if (header & 0xff == id) return off;
            off = @truncate((header >> 8) & 0xfc);
        }
        return null;
    }

    /// Turns on MSI-X and makes its entry 0 send `vector` to CPU 0. The device
    /// then writes the interrupt straight to the local APIC, no I/O APIC.
    pub fn enableMsix(d: Device, vector: u8) bool {
        const cap = d.capability(0x11) orelse return false;
        const table = d.read32(cap + 4); // BAR number in the low 3 bits + offset
        const bar_value = d.bar(@truncate(table & 7));
        if (bar_value & 1 != 0) return false; // the table must be in memory, not I/O ports
        var phys: u64 = bar_value & ~@as(u32, 0xf);
        if ((bar_value >> 1) & 3 == 2) phys |= @as(u64, d.bar(@truncate((table & 7) + 1))) << 32; // 64-bit BAR
        phys += table & ~@as(u32, 7);
        const entry: [*]volatile u32 = @ptrFromInt(paging.mapPhysical(phys, 16, paging.NO_CACHE));
        entry[0] = 0xfee0_0000; // local APIC, destination id 0
        entry[1] = 0;
        entry[2] = vector;
        entry[3] = 0; // not masked
        // message control is the upper half of the first dword: bit 15 = enable
        d.write32(cap, d.read32(cap) | (1 << 31));
        return true;
    }

    /// Lets the device answer I/O port and memory accesses, and read/write
    /// memory itself (bus master).
    pub fn enable(d: Device) void {
        const command = d.read32(0x04);
        d.write32(0x04, command | (1 << 0) | (1 << 1) | (1 << 2));
    }
};

/// The n-th device (from 0) with this vendor and device id.
pub fn find(vendor: u16, device: u16, n: usize) ?Device {
    var seen: usize = 0;
    for (0..256) |bus| {
        for (0..32) |slot| {
            for (0..8) |func| {
                const d: Device = .{ .bus = @intCast(bus), .slot = @intCast(slot), .func = @intCast(func) };
                if (d.vendor() == 0xffff) {
                    if (func == 0) break; // nothing in this slot
                    continue;
                }
                if (d.vendor() == vendor and d.deviceId() == device) {
                    if (seen == n) return d;
                    seen += 1;
                }
            }
        }
    }
    return null;
}
