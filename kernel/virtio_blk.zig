// virtio-blk: the disk QEMU gives us with -drive if=virtio.
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

const DESC_NEXT = 1;
const DESC_WRITE = 2; // the device writes into this buffer

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const RequestHeader = extern struct { type: u32, reserved: u32, sector: u64 };

var port: u16 = 0;
var queue_size: u16 = 0;
var descs: [*]volatile Desc = undefined;
var avail: [*]volatile u16 = undefined; // flags, idx, ring[queue_size]
var used: [*]volatile u16 = undefined; // flags, idx, then {id: u32, len: u32}[queue_size]
var last_used: u16 = 0;
// buffers the device reads/writes, need physical addresses
var request_frame: u64 = 0; // header at 0, status byte at 64
var data_frame: u64 = 0; // up to 8 sectors at a time
pub var capacity: u64 = 0;

pub fn init() bool {
    // 0x1af4 = virtio, 0x1001 = block device (legacy/transitional id)
    const dev = pci.find(0x1af4, 0x1001) orelse {
        log.warn("no virtio disk", .{});
        return false;
    };
    const bar0 = dev.bar(0);
    if (bar0 & 1 == 0) {
        log.err("virtio disk BAR0 isn't I/O ports", .{});
        return false;
    }
    port = @truncate(bar0 & ~@as(u32, 3));
    dev.enableIoAndBusMaster();

    cpu.outb(port + STATUS, 0); // reset
    cpu.outb(port + STATUS, STATUS_ACK);
    cpu.outb(port + STATUS, STATUS_ACK | STATUS_DRIVER);
    _ = cpu.inl(port + DEVICE_FEATURES);
    cpu.outl(port + GUEST_FEATURES, 0); // no extra features needed

    // queue 0: the only one a block device has
    cpu.outw(port + QUEUE_SELECT, 0);
    queue_size = cpu.inw(port + QUEUE_SIZE);
    if (queue_size == 0) return false;
    const n: u64 = queue_size;
    const used_offset = std.mem.alignForward(u64, 16 * n + 6 + 2 * n, 4096);
    const total = used_offset + std.mem.alignForward(u64, 6 + 8 * n, 4096);
    const ring = pmm.allocContiguous(total / 4096) orelse return false;
    descs = @ptrCast(@alignCast(pmm.toVirt(u8, ring)));
    avail = @ptrCast(@alignCast(pmm.toVirt(u8, ring + 16 * n)));
    used = @ptrCast(@alignCast(pmm.toVirt(u8, ring + used_offset)));
    avail[0] = 1; // no interrupts please, I'm polling
    cpu.outl(port + QUEUE_PFN, @intCast(ring / 4096));

    request_frame = pmm.alloc() orelse return false;
    data_frame = pmm.alloc() orelse return false;
    cpu.outb(port + STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK);

    capacity = @as(u64, cpu.inl(port + CAPACITY + 4)) << 32 | cpu.inl(port + CAPACITY);
    log.info("virtio disk: {d} sectors ({d} MiB), queue size {d}", .{ capacity, capacity * sector_size / (1024 * 1024), queue_size });
    return true;
}

pub const Error = error{ OutOfRange, DeviceError };

/// Reads `buf.len / 512` sectors starting at `sector` (up to 8 at a time).
pub fn read(sector: u64, buf: []u8) Error!void {
    std.debug.assert(buf.len % sector_size == 0 and buf.len <= 4096);
    if (sector + buf.len / sector_size > capacity) return error.OutOfRange;

    const irq = cpu.disableInterrupts(); // one request at a time
    defer cpu.restoreInterrupts(irq);

    const header = pmm.toVirt(RequestHeader, request_frame);
    header.* = .{ .type = 0, .reserved = 0, .sector = sector }; // 0 = read
    const status = pmm.toVirt(u8, request_frame + 64);
    status.* = 0xff;

    descs[0] = .{ .addr = request_frame, .len = @sizeOf(RequestHeader), .flags = DESC_NEXT, .next = 1 };
    descs[1] = .{ .addr = data_frame, .len = @intCast(buf.len), .flags = DESC_NEXT | DESC_WRITE, .next = 2 };
    descs[2] = .{ .addr = request_frame + 64, .len = 1, .flags = DESC_WRITE, .next = 0 };

    // put descriptor 0 (the start of the chain) on the available ring
    const idx = avail[1];
    avail[2 + idx % queue_size] = 0;
    avail[1] = idx +% 1;
    cpu.outw(port + QUEUE_NOTIFY, 0);

    // wait until the device is done with it
    var tries: u64 = 0;
    while (used[1] == last_used) : (tries += 1) {
        if (tries == 100_000_000) return error.DeviceError;
        std.atomic.spinLoopHint();
    }
    last_used +%= 1;
    if (status.* != 0) return error.DeviceError;
    @memcpy(buf, pmm.toVirt([4096]u8, data_frame)[0..buf.len]);
}
