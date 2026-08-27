// Physical memory: which 4 KiB pages (frames) of RAM are free.
// One bit per frame in a bitmap, 1 = used. Simple, not fast, good enough for now.

const std = @import("std");
const limine = @import("limine.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.pmm);

pub const page_size = 4096;

var bitmap: []u8 = &.{};
var frame_count: u64 = 0;
var free_count: u64 = 0;
var hhdm: u64 = 0;
var next: u64 = 0; // where to start looking, everything below is used

pub fn init() void {
    hhdm = limine.hhdmOffset() orelse @panic("no HHDM from Limine");
    const map = limine.memoryMap() orelse @panic("no memory map from Limine");

    // how many frames do we need to track: up to the end of the last usable entry
    var top: u64 = 0;
    for (map) |e| {
        log.debug("{x:0>16}-{x:0>16} type {d}", .{ e.base, e.base + e.length, e.type });
        if (e.type == 0) top = @max(top, e.base + e.length);
    }
    frame_count = top / page_size;
    const bitmap_size = (frame_count + 7) / 8;

    // put the bitmap at the start of the first usable entry that's big enough
    const home = for (map) |e| {
        if (e.type == 0 and e.length >= bitmap_size) break e;
    } else @panic("no room for the frame bitmap");
    bitmap = @as([*]u8, @ptrFromInt(hhdm + home.base))[0..bitmap_size];

    // everything used, then free the usable entries
    @memset(bitmap, 0xff);
    for (map) |e| {
        if (e.type != 0) continue;
        var f = e.base / page_size;
        while (f < (e.base + e.length) / page_size) : (f += 1) setFree(f);
    }
    // the bitmap itself is not free, and frame 0 neither (address 0 = null)
    var f = home.base / page_size;
    while (f < (home.base + bitmap_size + page_size - 1) / page_size) : (f += 1) setUsed(f);
    setUsed(0);

    log.info("{d} MiB free", .{free_count * page_size / (1024 * 1024)});
}

fn setUsed(f: u64) void {
    if (bitmap[f / 8] & bit(f) == 0) {
        bitmap[f / 8] |= bit(f);
        free_count -= 1;
    }
}

fn setFree(f: u64) void {
    if (bitmap[f / 8] & bit(f) != 0) {
        bitmap[f / 8] &= ~bit(f);
        free_count += 1;
    }
}

fn bit(f: u64) u8 {
    return @as(u8, 1) << @intCast(f % 8);
}

/// Physical address of a free frame, or null if we're out of memory.
pub fn alloc() ?u64 {
    const irq = cpu.disableInterrupts(); // see heap.zig
    defer cpu.restoreInterrupts(irq);
    var f = next;
    while (f < frame_count) : (f += 1) {
        if (bitmap[f / 8] & bit(f) == 0) {
            setUsed(f);
            next = f + 1;
            return f * page_size;
        }
    }
    return null;
}

pub fn free(phys: u64) void {
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    const f = phys / page_size;
    if (phys % page_size != 0 or f >= frame_count) @panic("pmm: freeing a bad address");
    if (bitmap[f / 8] & bit(f) == 0) @panic("pmm: double free");
    setFree(f);
    if (f < next) next = f;
}

pub fn freeCount() u64 {
    return free_count;
}

/// Pointer to physical memory through the direct map.
pub fn toVirt(comptime T: type, phys: u64) *T {
    return @ptrFromInt(hhdm + phys);
}
