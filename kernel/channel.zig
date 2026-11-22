// Channels: a pair of endpoints, what's sent into one comes out of the
// other. A message is up to 64 KiB of bytes plus up to 16 handles; the
// handles move out of the sender (who needs the transfer right for each)
// into the receiver, with the same rights.
//
// Each endpoint queues at most 16 messages, so a program can't make the
// kernel eat all memory by sending and never receiving. Receiving an empty
// endpoint waits; when the other end is closed it says so instead.
//
// Runs inside syscalls with interrupts off (one CPU), so no locks here.

const std = @import("std");
const heap = @import("heap.zig");
const thread = @import("thread.zig");
const process = @import("process.zig");

pub const max_bytes = 64 * 1024;
pub const max_handles = 16;
const max_queued = 16;

pub const Message = struct {
    node: std.DoublyLinkedList.Node = .{},
    bytes: []u8,
    handles: [max_handles]process.Handle = undefined,
    handle_count: usize = 0,

    /// Frees it and closes the handles that never got delivered.
    fn destroy(m: *Message) void {
        for (m.handles[0..m.handle_count]) |h| h.close();
        heap.allocator.free(m.bytes);
        heap.allocator.destroy(m);
    }
};

pub const Endpoint = struct {
    pair: *Pair,
    refs: u32 = 1, // handles to this end (in programs and in messages)
    queue: std.DoublyLinkedList = .{}, // messages sent to this end
    queued: usize = 0,
    waiters: thread.WaitQueue = .{},

    pub fn peer(e: *Endpoint) *Endpoint {
        return if (e == &e.pair.ends[0]) &e.pair.ends[1] else &e.pair.ends[0];
    }

    fn closed(e: *Endpoint) bool {
        return e.refs == 0;
    }

    pub fn open(e: *Endpoint) void {
        e.refs += 1;
    }

    /// One handle less. When the last one goes, the end is closed: its
    /// messages are dropped and the other side finds out.
    pub fn close(e: *Endpoint) void {
        e.refs -= 1;
        if (e.refs != 0) return;
        while (e.queue.popFirst()) |node| @as(*Message, @fieldParentPtr("node", node)).destroy();
        e.queued = 0;
        thread.wakeAll(&e.peer().waiters); // a receiver there sees "peer closed"
        if (e.peer().closed()) heap.allocator.destroy(e.pair);
    }
};

const Pair = struct { ends: [2]Endpoint };

pub fn create() ?*Pair {
    const pair = heap.allocator.create(Pair) catch return null;
    pair.* = .{ .ends = .{ .{ .pair = pair }, .{ .pair = pair } } };
    return pair;
}

pub const Error = error{ PeerClosed, QueueFull, TooBig, OutOfMemory };

/// Can the receiving end take another message? Checked before the handles
/// are taken out of the sender, so a failed send costs nothing.
pub fn canSend(from: *Endpoint, bytes: usize, handles: usize) Error!void {
    if (bytes > max_bytes or handles > max_handles) return error.TooBig;
    const to = from.peer();
    if (to.closed()) return error.PeerClosed;
    if (to.queued == max_queued) return error.QueueFull;
}

/// Queues a message on the other end. The handles are already out of the
/// sender's table, they belong to the message now.
pub fn send(from: *Endpoint, bytes: []const u8, handles: []const process.Handle) Error!void {
    try canSend(from, bytes.len, handles.len);
    const m = try heap.allocator.create(Message);
    errdefer heap.allocator.destroy(m);
    m.* = .{ .bytes = try heap.allocator.dupe(u8, bytes) };
    @memcpy(m.handles[0..handles.len], handles);
    m.handle_count = handles.len;
    const to = from.peer();
    to.queue.append(&m.node);
    to.queued += 1;
    thread.wakeAll(&to.waiters);
}

/// Waits for a message on this end. Null if there are none and the other
/// end is closed (or the thread got Ctrl+C). The caller takes the message
/// off the queue with `take` once it knows it can store it.
pub fn waitMessage(e: *Endpoint) ?*Message {
    while (e.queue.first == null) {
        if (e.peer().closed() or thread.wasKilled()) return null;
        thread.sleepOn(&e.waiters);
    }
    return @fieldParentPtr("node", e.queue.first.?);
}

/// Removes the first message (the one waitMessage returned) and frees it;
/// its handles were moved to the receiver already.
pub fn take(e: *Endpoint) void {
    const m: *Message = @fieldParentPtr("node", e.queue.popFirst().?);
    e.queued -= 1;
    m.handle_count = 0;
    m.destroy();
}
