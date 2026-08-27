// Kernel heap as a std.mem.Allocator, so std.ArrayList & co work in the kernel.
//
// Small stuff (up to 2 KiB): a page gets cut into equal pieces of 16, 32,
// ... 2048 bytes, kept on a free list per size. Freed pieces go back on the
// list, pages are never given back.
// Bigger stuff: whole pages, mapped one after another in a heap area of
// virtual memory, unmapped and returned to pmm on free.

const std = @import("std");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const cpu = @import("cpu.zig");

const page_size = pmm.page_size;
const sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };

const FreeNode = struct { next: ?*FreeNode };
var free_lists: [sizes.len]?*FreeNode = @splat(null);

// Virtual area for big allocations, far away from everything else.
// Addresses are never reused, there's plenty of them.
const big_area_start: u64 = 0xffff_e000_0000_0000;
var big_area_next: u64 = big_area_start;

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
};

fn sizeClass(len: usize, alignment: std.mem.Alignment) ?usize {
    const need = @max(len, alignment.toByteUnits());
    for (sizes, 0..) |size, i| {
        if (need <= size) return i;
    }
    return null;
}

fn pageCount(len: usize) usize {
    return (len + page_size - 1) / page_size;
}

// Threads can be switched in the middle of alloc/free, so interrupts are off
// while the free lists are touched. One CPU only, so that's enough of a lock.
fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    if (sizeClass(len, alignment)) |class| {
        if (free_lists[class] == null) refill(class) orelse return null;
        const node = free_lists[class].?;
        free_lists[class] = node.next;
        return @ptrCast(node);
    }
    if (alignment.toByteUnits() > page_size) return null;
    const start = big_area_next;
    for (0..pageCount(len)) |i| {
        const frame = pmm.alloc() orelse return null; // TODO: give back what we already took
        paging.map(start + i * page_size, frame, paging.WRITABLE | paging.NO_EXECUTE);
    }
    big_area_next += pageCount(len) * page_size;
    return @ptrFromInt(start);
}

// cut a new page into pieces of this size class
fn refill(class: usize) ?void {
    const page = pmm.alloc() orelse return null;
    const bytes = pmm.toVirt([page_size]u8, page);
    var offset: usize = 0;
    while (offset + sizes[class] <= page_size) : (offset += sizes[class]) {
        const node: *FreeNode = @ptrCast(@alignCast(&bytes[offset]));
        node.next = free_lists[class];
        free_lists[class] = node;
    }
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    if (sizeClass(memory.len, alignment)) |class| {
        const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));
        node.next = free_lists[class];
        free_lists[class] = node;
        return;
    }
    const start = @intFromPtr(memory.ptr);
    for (0..pageCount(memory.len)) |i| {
        pmm.free(paging.unmap(start + i * page_size));
    }
}

// growing/shrinking in place only works if it stays in the same size class
// (or the same number of pages), otherwise std copies to a new allocation
fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) bool {
    const old_class = sizeClass(memory.len, alignment);
    const new_class = sizeClass(new_len, alignment);
    if (old_class != null or new_class != null) return old_class == new_class;
    return pageCount(memory.len) == pageCount(new_len);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}
