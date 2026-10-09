// My own page tables instead of the ones Limine left. 4 levels
// (PML4 -> PDPT -> PD -> PT), 4 KiB pages only.
//
// Limine maps everything read+write+execute. Here:
//   kernel code    read + execute
//   kernel rodata  read only
//   kernel data    read + write, no execute
//   direct map     read + write, no execute
//
// Every user process gets its own PML4. The upper half (kernel) is shared:
// all 256 upper PML4 entries exist from boot, and new spaces copy them, so a
// kernel mapping made later shows up in every process.

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

var pml4: u64 = 0; // the kernel's, physical address

fn newTable() u64 {
    const phys = pmm.alloc() orelse @panic("out of memory for page tables");
    @memset(pmm.toVirt([512]u64, phys), 0);
    return phys;
}

/// Maps one 4 KiB page in the kernel's page tables.
pub fn map(virt: u64, phys: u64, flags: u64) void {
    mapIn(pml4, virt, phys, flags);
}

/// Maps one 4 KiB page in the page tables at `root`. Missing tables on the
/// way get created.
pub fn mapIn(root: u64, virt: u64, phys: u64, flags: u64) void {
    var table = pmm.toVirt([512]u64, root);
    var shift: u6 = 39;
    while (shift > 12) : (shift -= 9) {
        const entry = &table[(virt >> shift) & 0x1ff];
        if (entry.* & PRESENT == 0) {
            // upper levels allow everything, the last level decides
            entry.* = newTable() | PRESENT | WRITABLE;
        }
        // ring 3 can only reach a page if every level says USER
        entry.* |= flags & USER;
        table = pmm.toVirt([512]u64, entry.* & ADDRESS_MASK);
    }
    const entry = &table[(virt >> 12) & 0x1ff];
    if (entry.* & PRESENT != 0) @panic("page already mapped");
    entry.* = (phys & ADDRESS_MASK) | flags | PRESENT;
}

/// Removes the mapping of one page (kernel page tables) and returns the
/// physical address it had.
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

    // the whole kernel half exists from the start, so it can be shared
    const top = pmm.toVirt([512]u64, pml4);
    for (256..512) |i| {
        if (top[i] & PRESENT == 0) top[i] = newTable() | PRESENT | WRITABLE;
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

pub fn kernelRoot() u64 {
    return pml4;
}

/// A new address space: empty lower half, the kernel's upper half.
pub fn newAddressSpace() u64 {
    const root = newTable();
    const mine = pmm.toVirt([512]u64, root);
    const kernel = pmm.toVirt([512]u64, pml4);
    for (256..512) |i| mine[i] = kernel[i];
    return root;
}

/// Frees everything in the lower half of an address space (pages and the
/// tables pointing to them), then the PML4 itself. Must not be the active one.
pub fn freeAddressSpace(root: u64) void {
    const top = pmm.toVirt([512]u64, root);
    for (0..256) |i| {
        if (top[i] & PRESENT != 0) freeTable(top[i] & ADDRESS_MASK, 3);
    }
    pmm.free(root);
}

fn freeTable(phys: u64, level: u8) void {
    for (pmm.toVirt([512]u64, phys)) |entry| {
        if (entry & PRESENT == 0) continue;
        if (level == 1) pmm.free(entry & ADDRESS_MASK) else freeTable(entry & ADDRESS_MASK, level - 1);
    }
    pmm.free(phys);
}

/// True if every page in [addr, addr + len) is mapped in `root` for user
/// mode (and writable, if `write`). Syscalls check this before touching a
/// pointer a program gave them; otherwise a bad pointer would page fault
/// inside the kernel.
pub fn userCanAccess(root: u64, addr: u64, len: u64, write: bool) bool {
    if (len == 0) return true;
    const end = std.math.add(u64, addr, len) catch return false;
    if (end > 0x8000_0000_0000) return false;
    var page = std.mem.alignBackward(u64, addr, page_size);
    while (page < end) : (page += page_size) {
        var table = pmm.toVirt([512]u64, root);
        var shift: u6 = 39;
        while (true) : (shift -= 9) {
            const entry = table[(page >> shift) & 0x1ff];
            if (entry & PRESENT == 0 or entry & USER == 0) return false;
            if (shift == 12) {
                if (write and entry & WRITABLE == 0) return false;
                break;
            }
            table = pmm.toVirt([512]u64, entry & ADDRESS_MASK);
        }
    }
    return true;
}

pub fn activate(root: u64) void {
    asm volatile ("movq %[root], %%cr3"
        :
        : [root] "r" (root),
        : .{ .memory = true });
}
