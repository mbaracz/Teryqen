// PCI: finding devices. The old way through I/O ports 0xcf8/0xcfc
// ("configuration mechanism #1"), enough for QEMU.

const cpu = @import("cpu.zig");
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

    /// Lets the device answer I/O port accesses and read/write memory itself.
    pub fn enableIoAndBusMaster(d: Device) void {
        const command = d.read32(0x04);
        d.write32(0x04, command | (1 << 0) | (1 << 2));
    }
};

/// The first device with this vendor and device id.
pub fn find(vendor: u16, device: u16) ?Device {
    for (0..256) |bus| {
        for (0..32) |slot| {
            for (0..8) |func| {
                const d: Device = .{ .bus = @intCast(bus), .slot = @intCast(slot), .func = @intCast(func) };
                if (d.vendor() == 0xffff) {
                    if (func == 0) break; // nothing in this slot
                    continue;
                }
                if (d.vendor() == vendor and d.deviceId() == device) return d;
            }
        }
    }
    return null;
}
