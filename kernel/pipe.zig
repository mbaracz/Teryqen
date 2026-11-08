// Pipes: a 4 KiB buffer one program writes into and another reads from
// (`ls | wc`). Reading an empty pipe waits for data, writing a full one waits
// for room. When every writer is gone a reader gets 0 (end of file); when
// every reader is gone, writing fails.
//
// All of this runs inside syscalls, where interrupts are off, so checking
// and then sleeping can't miss a wakeup.

const std = @import("std");
const heap = @import("heap.zig");
const thread = @import("thread.zig");

pub const Pipe = struct {
    buf: [4096]u8 = undefined,
    start: usize = 0,
    len: usize = 0,
    readers: u32 = 1, // open read ends (in all programs)
    writers: u32 = 1,
    waiters: thread.WaitQueue = .{}, // readers and writers waiting

    pub fn read(p: *Pipe, out: []u8) usize {
        while (p.len == 0) {
            if (p.writers == 0) return 0; // end of file
            thread.sleepOn(&p.waiters);
        }
        const n = @min(out.len, p.len);
        for (out[0..n], 0..) |*b, i| b.* = p.buf[(p.start + i) % p.buf.len];
        p.start = (p.start + n) % p.buf.len;
        p.len -= n;
        thread.wakeAll(&p.waiters); // there's room for writers now
        return n;
    }

    /// Writes everything, waiting for room as needed. Null if nobody reads
    /// anymore.
    pub fn write(p: *Pipe, data: []const u8) ?usize {
        var done: usize = 0;
        while (done < data.len) {
            if (p.readers == 0) return null;
            if (p.len == p.buf.len) {
                thread.sleepOn(&p.waiters);
                continue;
            }
            const n = @min(data.len - done, p.buf.len - p.len);
            for (data[done..][0..n], 0..) |b, i| p.buf[(p.start + p.len + i) % p.buf.len] = b;
            p.len += n;
            done += n;
            thread.wakeAll(&p.waiters); // there's data for readers now
        }
        return done;
    }

    pub fn open(p: *Pipe, writer: bool) void {
        if (writer) p.writers += 1 else p.readers += 1;
    }

    /// One end closed. The pipe goes away when both sides are closed.
    pub fn close(p: *Pipe, writer: bool) void {
        if (writer) p.writers -= 1 else p.readers -= 1;
        thread.wakeAll(&p.waiters); // a reader may get end of file now
        if (p.readers == 0 and p.writers == 0) heap.allocator.destroy(p);
    }
};

pub fn create() ?*Pipe {
    const p = heap.allocator.create(Pipe) catch return null;
    p.* = .{};
    return p;
}
