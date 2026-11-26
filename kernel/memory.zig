// Memory objects: some pages that more than one program can map, to share
// data without copying it through a channel. One program makes it, sends
// the handle over a channel, the other maps the same pages.
//
// The pages stay as long as there are handles to it or it's mapped
// somewhere.

const std = @import("std");
const heap = @import("heap.zig");
const pmm = @import("pmm.zig");

pub const max_size = 16 * 1024 * 1024;

pub const MemoryObject = struct {
    frames: []u64, // physical pages
    refs: u32 = 1, // handles + mappings

    pub fn size(m: *const MemoryObject) u64 {
        return m.frames.len * pmm.page_size;
    }

    pub fn open(m: *MemoryObject) void {
        m.refs += 1;
    }

    pub fn close(m: *MemoryObject) void {
        m.refs -= 1;
        if (m.refs != 0) return;
        for (m.frames) |f| pmm.free(f);
        heap.allocator.free(m.frames);
        heap.allocator.destroy(m);
    }
};

/// Zeroed pages, `bytes` rounded up to whole pages.
pub fn create(bytes: u64) ?*MemoryObject {
    if (bytes == 0 or bytes > max_size) return null;
    const count = (bytes + pmm.page_size - 1) / pmm.page_size;
    const m = heap.allocator.create(MemoryObject) catch return null;
    m.* = .{ .frames = heap.allocator.alloc(u64, count) catch {
        heap.allocator.destroy(m);
        return null;
    } };
    for (m.frames, 0..) |*f, i| {
        f.* = pmm.alloc() orelse {
            for (m.frames[0..i]) |taken| pmm.free(taken);
            heap.allocator.free(m.frames);
            heap.allocator.destroy(m);
            return null;
        };
        @memset(pmm.toVirt([4096]u8, f.*), 0);
    }
    return m;
}
