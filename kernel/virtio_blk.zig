// virtio-blk: the disks QEMU gives us with -drive if=virtio. The first one is
// the boot disk, the second one (if there is one) is for saving files.
//
// Uses the "legacy" virtio interface: registers in an I/O port range
// (BAR0), one queue in physically contiguous memory that both the kernel and
// the device read and write. A request is three descriptors chained together:
// header (read or write, which sector) -> data -> status byte. Then poke the
// notify register and wait until the device puts it on the "used" ring.
// No interrupts yet, it just polls.

const std = @import("std");
const cpu = @import("cpu.zig");
const pci = @import("pci.zig");
const pmm = @import("pmm.zig");

const log = std.log.scoped(.virtio_blk);

pub const sector_size = 512;

// legacy register offsets from BAR0
const DEVICE_FEATURES = 0x00;
const GUEST_FEATURES = 0x04;
const QUEUE_PFN = 0x08;
const QUEUE_SIZE = 0x0c;
const QUEUE_SELECT = 0x0e;
const QUEUE_NOTIFY = 0x10;
const STATUS = 0x12;
const CAPACITY = 0x14; // in sectors, 64 bit

const STATUS_ACK = 1;
const STATUS_DRIVER = 2;
const STATUS_DRIVER_OK = 4;

const FEATURE_READ_ONLY = 1 << 5;

const DESC_NEXT = 1;
const DESC_WRITE = 2; // the device writes into this buffer

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const RequestHeader = extern struct { type: u32, reserved: u32, sector: u64 };

pub const Disk = struct {
    port: u16,
    queue_size: u16,
    descs: [*]volatile Desc,
    avail: [*]volatile u16, // flags, idx, ring[queue_size]
    used: [*]volatile u16, // flags, idx, then {id: u32, len: u32}[queue_size]
    last_used: u16 = 0,
    // buffers the device reads/writes, need physical addresses
    request_frame: u64, // header at 0, status byte at 64
    data_frame: u64, // up to 8 sectors at a time
    capacity: u64, // in sectors
    read_only: bool,

    pub const Error = error{ OutOfRange, ReadOnly, DeviceError };

    /// Reads `buf.len / 512` sectors starting at `sector` (up to 8 at a time).
    pub fn read(d: *Disk, sector: u64, buf: []u8) Error!void {
        try d.request(0, sector, buf.len);
        @memcpy(buf, pmm.toVirt([4096]u8, d.data_frame)[0..buf.len]);
    }

    /// Writes `buf.len / 512` sectors starting at `sector` (up to 8 at a time).
    pub fn write(d: *Disk, sector: u64, buf: []const u8) Error!void {
        if (d.read_only) return error.ReadOnly;
        @memcpy(pmm.toVirt([4096]u8, d.data_frame)[0..buf.len], buf);
        try d.request(1, sector, buf.len);
    }

    fn request(d: *Disk, kind: u32, sector: u64, len: usize) Error!void {
        std.debug.assert(len % sector_size == 0 and len <= 4096);
        if (sector + len / sector_size > d.capacity) return error.OutOfRange;

        const irq = cpu.disableInterrupts(); // one request at a time
        defer cpu.restoreInterrupts(irq);

        const header = pmm.toVirt(RequestHeader, d.request_frame);
        header.* = .{ .type = kind, .reserved = 0, .sector = sector }; // 0 = read, 1 = write
        const status = pmm.toVirt(u8, d.request_frame + 64);
        status.* = 0xff;

        // for a read the device writes the data buffer, for a write it reads it
        const data_flags: u16 = if (kind == 0) DESC_NEXT | DESC_WRITE else DESC_NEXT;
        d.descs[0] = .{ .addr = d.request_frame, .len = @sizeOf(RequestHeader), .flags = DESC_NEXT, .next = 1 };
        d.descs[1] = .{ .addr = d.data_frame, .len = @intCast(len), .flags = data_flags, .next = 2 };
        d.descs[2] = .{ .addr = d.request_frame + 64, .len = 1, .flags = DESC_WRITE, .next = 0 };

        // put descriptor 0 (the start of the chain) on the available ring
        const idx = d.avail[1];
        d.avail[2 + idx % d.queue_size] = 0;
        d.avail[1] = idx +% 1;
        cpu.outw(d.port + QUEUE_NOTIFY, 0);

        // wait until the device is done with it
        var tries: u64 = 0;
        while (d.used[1] == d.last_used) : (tries += 1) {
            if (tries == 100_000_000) return error.DeviceError;
            std.atomic.spinLoopHint();
        }
        d.last_used +%= 1;
        if (status.* != 0) return error.DeviceError;
    }
};

var disks: [4]Disk = undefined;
var disk_count: usize = 0;

/// Sets up every virtio disk. disk(0) is the boot disk.
pub fn init() void {
    // 0x1af4 = virtio, 0x1001 = block device (legacy/transitional id)
    while (disk_count < disks.len) {
        const dev = pci.find(0x1af4, 0x1001, disk_count) orelse break;
        disks[disk_count] = setUp(dev) orelse break;
        const d = &disks[disk_count];
        log.info("virtio disk {d}: {d} sectors ({d} MiB){s}", .{ disk_count, d.capacity, d.capacity * sector_size / (1024 * 1024), if (d.read_only) ", read only" else "" });
        disk_count += 1;
    }
    if (disk_count == 0) log.warn("no virtio disk", .{});
}

pub fn disk(n: usize) ?*Disk {
    return if (n < disk_count) &disks[n] else null;
}

fn setUp(dev: pci.Device) ?Disk {
    const bar0 = dev.bar(0);
    if (bar0 & 1 == 0) {
        log.err("virtio disk BAR0 isn't I/O ports", .{});
        return null;
    }
    const port: u16 = @truncate(bar0 & ~@as(u32, 3));
    dev.enableIoAndBusMaster();

    cpu.outb(port + STATUS, 0); // reset
    cpu.outb(port + STATUS, STATUS_ACK);
    cpu.outb(port + STATUS, STATUS_ACK | STATUS_DRIVER);
    const features = cpu.inl(port + DEVICE_FEATURES);
    cpu.outl(port + GUEST_FEATURES, features & FEATURE_READ_ONLY); // just want to know

    // queue 0: the only one a block device has
    cpu.outw(port + QUEUE_SELECT, 0);
    const queue_size = cpu.inw(port + QUEUE_SIZE);
    if (queue_size == 0) return null;
    const n: u64 = queue_size;
    const used_offset = std.mem.alignForward(u64, 16 * n + 6 + 2 * n, 4096);
    const total = used_offset + std.mem.alignForward(u64, 6 + 8 * n, 4096);
    const ring = pmm.allocContiguous(total / 4096) orelse return null;
    const avail: [*]volatile u16 = @ptrCast(@alignCast(pmm.toVirt(u8, ring + 16 * n)));
    avail[0] = 1; // no interrupts please, I'm polling
    cpu.outl(port + QUEUE_PFN, @intCast(ring / 4096));
    cpu.outb(port + STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK);

    return .{
        .port = port,
        .queue_size = queue_size,
        .descs = @ptrCast(@alignCast(pmm.toVirt(u8, ring))),
        .avail = avail,
        .used = @ptrCast(@alignCast(pmm.toVirt(u8, ring + used_offset))),
        .request_frame = pmm.alloc() orelse return null,
        .data_frame = pmm.alloc() orelse return null,
        .capacity = @as(u64, cpu.inl(port + CAPACITY + 4)) << 32 | cpu.inl(port + CAPACITY),
        .read_only = features & FEATURE_READ_ONLY != 0,
    };
}
