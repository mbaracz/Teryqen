// My own page tables instead of the ones Limine left. 4 levels
// (PML4 -> PDPT -> PD -> PT), 4 KiB pages only.
//
// Limine maps everything read+write+execute. Here:
//   kernel code    read + execute
//   kernel rodata  read only
//   kernel data    read + write, no execute
//   direct map     read + write, no execute

const std = @import("std");
const limine = @import("limine.zig");
const pmm = @import("pmm.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.paging);

pub const PRESENT: u64 = 1 << 0;
pub const WRITABLE: u64 = 1 << 1;
pub const USER: u64 = 1 << 2;
pub const NO_EXECUTE: u64 = 1 << 63;

const ADDRESS_MASK: u64 = 0x000f_ffff_ffff_f000;
const page_size = pmm.page_size;

var pml4: u64 = 0; // physical address

fn newTable() u64 {
    const phys = pmm.alloc() orelse @panic("out of memory for page tables");
    @memset(pmm.toVirt([512]u64, phys), 0);
    return phys;
}

/// Maps one 4 KiB page. Missing tables on the way get created.
pub fn map(virt: u64, phys: u64, flags: u64) void {
    var table = pmm.toVirt([512]u64, pml4);
    var shift: u6 = 39;
    while (shift > 12) : (shift -= 9) {
        const entry = &table[(virt >> shift) & 0x1ff];
        if (entry.* & PRESENT == 0) {
            // upper levels allow everything, the last level decides
            entry.* = newTable() | PRESENT | WRITABLE;
        }
        table = pmm.toVirt([512]u64, entry.* & ADDRESS_MASK);
    }
    const entry = &table[(virt >> 12) & 0x1ff];
    if (entry.* & PRESENT != 0) @panic("page already mapped");
    entry.* = (phys & ADDRESS_MASK) | flags | PRESENT;
}

/// Removes the mapping of one page and returns the physical address it had.
pub fn unmap(virt: u64) u64 {
    var table = pmm.toVirt([512]u64, pml4);
    var shift: u6 = 39;
    while (shift > 12) : (shift -= 9) {
        const entry = table[(virt >> shift) & 0x1ff];
        if (entry & PRESENT == 0) @panic("unmap: page not mapped");
        table = pmm.toVirt([512]u64, entry & ADDRESS_MASK);
    }
    const entry = &table[(virt >> 12) & 0x1ff];
    if (entry.* & PRESENT == 0) @panic("unmap: page not mapped");
    const phys = entry.* & ADDRESS_MASK;
    entry.* = 0;
    // the CPU may still remember the old mapping
    asm volatile ("invlpg (%[virt])"
        :
        : [virt] "r" (virt),
        : .{ .memory = true });
    return phys;
}

fn mapRange(virt: u64, phys: u64, size: u64, flags: u64) void {
    var offset: u64 = 0;
    while (offset < size) : (offset += page_size) map(virt + offset, phys + offset, flags);
}

fn isMapped(virt: u64) bool {
    var table = pmm.toVirt([512]u64, pml4);
    var shift: u6 = 39;
    while (shift >= 12) : (shift -= 9) {
        const entry = table[(virt >> shift) & 0x1ff];
        if (entry & PRESENT == 0) return false;
        if (shift == 12) return true;
        table = pmm.toVirt([512]u64, entry & ADDRESS_MASK);
    }
    unreachable;
}

extern const __kernel_start: u8;
extern const __text_end: u8;
extern const __rodata_end: u8;
extern const __kernel_end: u8;

pub fn init() void {
    const kernel = limine.kernelAddress() orelse @panic("Limine didn't tell where the kernel is");
    const hhdm = limine.hhdmOffset().?;
    pml4 = newTable();

    // the kernel itself, by section
    const start = @intFromPtr(&__kernel_start);
    const text_end = @intFromPtr(&__text_end);
    const rodata_end = @intFromPtr(&__rodata_end);
    const end = @intFromPtr(&__kernel_end);
    const phys = kernel.physical_base;
    const virt = kernel.virtual_base;
    mapRange(start, phys + (start - virt), text_end - start, 0);
    mapRange(text_end, phys + (text_end - virt), rodata_end - text_end, NO_EXECUTE);
    mapRange(rodata_end, phys + (rodata_end - virt), end - rodata_end, WRITABLE | NO_EXECUTE);

    // the direct map, for the same kinds of memory Limine maps there
    // (not "reserved" (1) and "bad memory" (4))
    var pages: u64 = 0;
    for (limine.memoryMap().?) |e| {
        if (e.type == 1 or e.type == 4) continue;
        var p = std.mem.alignBackward(u64, e.base, page_size);
        while (p < e.base + e.length) : (p += page_size) {
            // two entries can share a page at the edges
            if (isMapped(hhdm + p)) continue;
            map(hhdm + p, p, WRITABLE | NO_EXECUTE);
            pages += 1;
        }
    }

    // NX bit only works with EFER.NXE on
    const efer = cpu.rdmsr(0xc0000080);
    cpu.wrmsr(0xc0000080, efer | (1 << 11));

    asm volatile ("movq %[pml4], %%cr3"
        :
        : [pml4] "r" (pml4),
        : .{ .memory = true });
    log.info("own page tables active, direct map {d} MiB", .{pages * page_size / (1024 * 1024)});
}
