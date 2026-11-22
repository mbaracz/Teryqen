// User mode (ring 3) and system calls.
//
// A user program calls the kernel with the `syscall` instruction:
//   rax = number, rdi/rsi/rdx = arguments, result comes back in rax
//   (all ones = error).
//   0 exit(code)            1 write(h, ptr, len)    2 yield()
//   3 read(h, ptr, len)     4 spawn(ptr, len, hs)   5 wait(pid)
//   6 open(ptr, len, flags) 7 close(h)              8 readdir(h, ptr, len)
//   9 args(ptr, len)        10 mkdir(ptr, len)      11 remove(ptr, len)
//  12 chdir(ptr, len)      13 getcwd(ptr, len)     14 sync()
//  15 sleep(ms)            16 uptime() -> ms       17 pipe() -> handles
//  18 handle_duplicate(h, rights) -> new handle    19 handle_reduce(h, rights)
//  20 channel_create() -> h0 | h1 << 32
//  21 channel_send(h, *SendArgs)   22 channel_recv(h, *RecvArgs) -> bytes
// Paths can be relative to the current directory.
// Handles are small numbers, every one has rights (read, write, duplicate,
// transfer; process.Rights) that read/write/... check. Rights only shrink:
// a duplicate gets at most what the original has, reduce takes some away.
// Handle 0 is stdin, 1 stdout (the keyboard and the console, unless the
// program was started with a pipe there). open() with flags 1 creates the
// file (or empties it) for writing. pipe() returns read h | write h << 32,
// spawn's `hs` is (stdin h + 1) | (stdout h + 1) << 16 | (extra h + 1) << 32,
// 0 = keep mine / none; extra becomes the new program's handle 2. Giving a
// handle to a program needs the transfer right.
// Channels (kernel/channel.zig): send and recv need more than 3 arguments,
// so they get a pointer to a struct (SendArgs/RecvArgs below). recv returns
// `peer_closed` when nothing is queued and the other end is gone.
// The CPU jumps to syscallEntry with the user's rsp still loaded, so the
// entry first switches to the thread's kernel stack.

const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const thread = @import("thread.zig");
const serial = @import("serial.zig");
const console = @import("console.zig");
const process = @import("process.zig");
const keyboard = @import("keyboard.zig");
const fs = @import("fs.zig");
const datadisk = @import("datadisk.zig");
const timer = @import("timer.zig");
const pipe_mod = @import("pipe.zig");
const channel = @import("channel.zig");
const heap = @import("heap.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(.syscall);

const EFER = 0xc0000080;
const STAR = 0xc0000081;
const LSTAR = 0xc0000082;
const FMASK = 0xc0000084;

// Used by syscallEntry. One CPU, so plain globals are fine.
export var kernel_rsp: u64 = 0; // set on every thread switch
export var user_rsp_scratch: u64 = 0;

pub var console_ready = false;

pub fn init() void {
    cpu.wrmsr(EFER, cpu.rdmsr(EFER) | 1); // SCE: syscall enable
    // kernel CS for syscall at bits 32..47; sysret uses (bits 48..63) + 8 for
    // SS and + 16 for CS, so 0x10 gives user data 0x18 and user code 0x20
    cpu.wrmsr(STAR, (@as(u64, 0x10) << 48) | (@as(u64, gdt.kernel_code) << 32));
    cpu.wrmsr(LSTAR, @intFromPtr(&syscallEntry));
    cpu.wrmsr(FMASK, 1 << 9); // interrupts off while in the kernel
}

/// Called by thread.zig when it switches to a thread with this kernel stack.
pub fn setKernelStack(top: u64) void {
    kernel_rsp = top;
    gdt.setKernelStack(top);
}

export fn syscallEntry() callconv(.naked) void {
    asm volatile (
        \\movq %%rsp, user_rsp_scratch(%%rip)
        \\movq kernel_rsp(%%rip), %%rsp
        // save what we need to go back, on the kernel stack (another thread
        // may do a syscall before we return, so not in a global)
        \\pushq user_rsp_scratch(%%rip)
        \\pushq %%rcx
        \\pushq %%r11
        // don't leak kernel values in the registers the handler is free to change
        \\pushq %%rdi
        \\pushq %%rsi
        \\pushq %%rdx
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\subq $8, %%rsp
        // handleSyscall(number, a, b, c)
        \\movq %%rdx, %%rcx
        \\movq %%rsi, %%rdx
        \\movq %%rdi, %%rsi
        \\movq %%rax, %%rdi
        \\callq handleSyscall
        \\addq $8, %%rsp
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdx
        \\popq %%rsi
        \\popq %%rdi
        \\popq %%r11
        \\popq %%rcx
        \\popq %%rsp
        \\sysretq
    );
}

const failed = process.failed;

export fn handleSyscall(number: u64, a: u64, b: u64, c: u64) callconv(.c) u64 {
    const result = doSyscall(number, a, b, c);
    // Ctrl+C while in here: stop before going back to the program
    if (thread.wasKilled()) process.exit(130);
    return result;
}

fn doSyscall(number: u64, a: u64, b: u64, c: u64) u64 {
    const p = process.current();
    switch (number) {
        0 => {
            log.debug("thread {d}: program exited with {d}", .{ thread.currentId(), a });
            process.exit(a);
        },
        1 => {
            const data = userSlice(b, c, false) orelse return failed;
            const h = getHandle(p, a, .{ .write = true }) orelse return failed;
            switch (h.object) {
                .console => {
                    serial.write(data);
                    if (console_ready) console.write(data);
                    return data.len;
                },
                .pipe_write => |pipe| return pipe.write(data) orelse failed,
                .file => |*file| {
                    if (file.node.is_dir) return failed;
                    // writing past the end makes the file longer
                    const end = file.pos + data.len;
                    if (end > file.node.data.items.len) file.node.data.resize(heap.allocator, end) catch return failed;
                    @memcpy(file.node.data.items[file.pos..end], data);
                    file.pos = end;
                    return data.len;
                },
                else => return failed,
            }
        },
        2 => {
            thread.yield();
            return 0;
        },
        3 => {
            const buf = userSlice(b, c, true) orelse return failed;
            const h = getHandle(p, a, .{ .read = true }) orelse return failed;
            switch (h.object) {
                .keyboard => return keyboard.read(buf),
                .pipe_read => |pipe| return pipe.read(buf),
                .file => |*file| {
                    if (file.node.is_dir) return failed;
                    const left = file.node.data.items[@min(file.pos, file.node.data.items.len)..];
                    const n = @min(buf.len, left.len);
                    @memcpy(buf[0..n], left[0..n]);
                    file.pos += n;
                    return n;
                },
                else => return failed,
            }
        },
        4 => {
            const cmdline = userSlice(a, b, false) orelse return failed;
            const in_fd = c & 0xffff;
            const out_fd = (c >> 16) & 0xffff;
            const stdin: ?process.Handle = if (in_fd == 0) null else (getHandle(p, in_fd - 1, .{ .transfer = true }) orelse return failed).*;
            const stdout: ?process.Handle = if (out_fd == 0) null else (getHandle(p, out_fd - 1, .{ .transfer = true }) orelse return failed).*;
            const extra_h = (c >> 32) & 0xffff;
            const extra: ?process.Handle = if (extra_h == 0) null else (getHandle(p, extra_h - 1, .{ .transfer = true }) orelse return failed).*;
            return process.spawn(cmdline, stdin, stdout, extra) orelse failed;
        },
        5 => return process.wait(a),
        6 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b, false) orelse return failed, &buf) orelse return failed;
            const node = (if (c == 1) fs.create(path, false) else fs.lookup(path)) catch return failed;
            const rights: process.Rights = if (c == 1 or node.is_dir) .all else .{ .read = true, .duplicate = true, .transfer = true };
            return addHandle(p, .{ .object = .{ .file = .{ .node = node } }, .rights = rights }) orelse failed;
        },
        7 => {
            const h = getHandle(p, a, .{}) orelse return failed;
            h.close();
            p.handles[a] = null;
            return 0;
        },
        8 => {
            // names of everything in the directory, one per line, "/" after
            // directories
            const buf = userSlice(b, c, true) orelse return failed;
            const h = getHandle(p, a, .{ .read = true }) orelse return failed;
            if (h.object != .file or !h.object.file.node.is_dir) return failed;
            const file = &h.object.file;
            var w: std.Io.Writer = .fixed(buf);
            for (file.node.children.items) |child| {
                w.print("{s}{s}\n", .{ child.getName(), if (child.is_dir) "/" else "" }) catch break;
            }
            return w.end;
        },
        9 => {
            const buf = userSlice(a, b, true) orelse return failed;
            const n = @min(buf.len, p.args().len);
            @memcpy(buf[0..n], p.args()[0..n]);
            return n;
        },
        10 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b, false) orelse return failed, &buf) orelse return failed;
            _ = fs.mkdir(path) catch return failed;
            return 0;
        },
        11 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b, false) orelse return failed, &buf) orelse return failed;
            const node = fs.lookup(path) catch return failed;
            // someone still using it would be left with a pointer to freed memory
            if (process.isOpen(node)) return failed;
            fs.remove(path) catch return failed;
            return 0;
        },
        12 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b, false) orelse return failed, &buf) orelse return failed;
            const node = fs.lookup(path) catch return failed;
            if (!node.is_dir or path.len > p.cwd.len) return failed;
            @memcpy(p.cwd[0..path.len], path);
            p.cwd_len = path.len;
            return 0;
        },
        13 => {
            const out = userSlice(a, b, true) orelse return failed;
            const n = @min(out.len, p.cwd_len);
            @memcpy(out[0..n], p.getCwd()[0..n]);
            return n;
        },
        14 => return datadisk.sync() catch failed,
        15 => {
            // timer ticks are 10 ms, round up
            thread.sleepTicks((a + 1000 / timer.hz - 1) / (1000 / timer.hz));
            return 0;
        },
        16 => return timer.ticksSinceBoot() * (1000 / timer.hz),
        17 => {
            const pipe = pipe_mod.create() orelse return failed;
            const r = addHandle(p, .{ .object = .{ .pipe_read = pipe }, .rights = .{ .read = true, .duplicate = true, .transfer = true } }) orelse {
                pipe.close(false);
                pipe.close(true);
                return failed;
            };
            const w = addHandle(p, .{ .object = .{ .pipe_write = pipe }, .rights = .{ .write = true, .duplicate = true, .transfer = true } }) orelse {
                p.handles[r] = null;
                pipe.close(false);
                pipe.close(true);
                return failed;
            };
            return r | (w << 32);
        },
        18 => {
            const h = getHandle(p, a, .{ .duplicate = true }) orelse return failed;
            var copy = h.dup();
            copy.rights = h.rights.intersect(@bitCast(@as(u8, @truncate(b))));
            return addHandle(p, copy) orelse {
                copy.close();
                return failed;
            };
        },
        19 => {
            const h = getHandle(p, a, .{}) orelse return failed;
            h.rights = h.rights.intersect(@bitCast(@as(u8, @truncate(b))));
            return 0;
        },
        20 => {
            const pair = channel.create() orelse return failed;
            const h0 = addHandle(p, .{ .object = .{ .channel = &pair.ends[0] }, .rights = .all }) orelse {
                pair.ends[0].close();
                pair.ends[1].close();
                return failed;
            };
            const h1 = addHandle(p, .{ .object = .{ .channel = &pair.ends[1] }, .rights = .all }) orelse {
                p.handles[h0] = null;
                pair.ends[0].close();
                pair.ends[1].close();
                return failed;
            };
            return h0 | (h1 << 32);
        },
        21 => return channelSend(p, a, b),
        22 => return channelRecv(p, a, b),
        else => return failed,
    }
}

const SendArgs = extern struct { bytes: u64, bytes_len: u64, handles: u64, handles_len: u64 };
const RecvArgs = extern struct { bytes: u64, bytes_len: u64, handles: u64, handles_len: u64, got_handles: u64 };
pub const peer_closed = failed - 1;

fn channelSend(p: *process.Process, h: u64, args_ptr: u64) u64 {
    const ep = (getHandle(p, h, .{ .write = true }) orelse return failed).object;
    if (ep != .channel) return failed;
    const raw = userSlice(args_ptr, @sizeOf(SendArgs), false) orelse return failed;
    const args = std.mem.bytesToValue(SendArgs, raw[0..@sizeOf(SendArgs)]);
    if (args.bytes_len > channel.max_bytes or args.handles_len > channel.max_handles) return failed;
    const bytes = userSliceBig(args.bytes, args.bytes_len, false) orelse return failed;
    const numbers_raw = userSlice(args.handles, args.handles_len * 8, false) orelse return failed;
    const numbers = std.mem.bytesAsSlice(u64, numbers_raw);
    // check everything before taking any handle away from the sender
    channel.canSend(ep.channel, bytes.len, numbers.len) catch |err| return if (err == error.PeerClosed) peer_closed else failed;
    var moving: [channel.max_handles]process.Handle = undefined;
    for (numbers, 0..) |n, i| {
        if (n == h) return failed; // not the end we send through
        for (numbers[0..i]) |earlier| if (earlier == n) return failed; // twice
        const moved = getHandle(p, n, .{ .transfer = true }) orelse return failed;
        // an end can't travel through its own channel
        if (moved.object == .channel and moved.object.channel.pair == ep.channel.pair) return failed;
        moving[i] = moved.*;
    }
    channel.send(ep.channel, bytes, moving[0..numbers.len]) catch return failed;
    for (numbers) |n| p.handles[n] = null; // they're in the message now
    return 0;
}

fn channelRecv(p: *process.Process, h: u64, args_ptr: u64) u64 {
    const ep = (getHandle(p, h, .{ .read = true }) orelse return failed).object;
    if (ep != .channel) return failed;
    const raw = userSlice(args_ptr, @sizeOf(RecvArgs), true) orelse return failed;
    const args = std.mem.bytesToValue(RecvArgs, raw[0..@sizeOf(RecvArgs)]);
    const m = channel.waitMessage(ep.channel) orelse return peer_closed;
    // the buffers have to be big enough, otherwise the message stays queued
    if (m.bytes.len > args.bytes_len or m.handle_count > args.handles_len) return failed;
    const bytes = userSliceBig(args.bytes, m.bytes.len, true) orelse return failed;
    const numbers_raw = userSlice(args.handles, m.handle_count * 8, true) orelse return failed;
    var free_slots: usize = 0;
    for (p.handles) |slot| {
        if (slot == null) free_slots += 1;
    }
    if (free_slots < m.handle_count) return failed;
    @memcpy(bytes, m.bytes);
    const numbers = std.mem.bytesAsSlice(u64, numbers_raw);
    for (m.handles[0..m.handle_count], 0..) |moved, i| numbers[i] = addHandle(p, moved).?;
    std.mem.writeInt(u64, raw[@offsetOf(RecvArgs, "got_handles")..][0..8], m.handle_count, .little);
    const len = m.bytes.len;
    channel.take(ep.channel);
    return len;
}

/// Like userSlice, for buffers bigger than a page (channel messages).
fn userSliceBig(ptr: u64, len: u64, kernel_writes: bool) ?[]u8 {
    if (len > channel.max_bytes) return null;
    if (!paging.userCanAccess(thread.addressSpace(), ptr, len, kernel_writes)) return null;
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}

/// The handle, if the program has it and it has (at least) `needed` rights.
fn getHandle(p: *process.Process, n: u64, needed: process.Rights) ?*process.Handle {
    if (n >= p.handles.len) return null;
    if (p.handles[n]) |*h| {
        const want: u8 = @bitCast(needed);
        if (@as(u8, @bitCast(h.rights)) & want != want) return null;
        return h;
    }
    return null;
}

fn addHandle(p: *process.Process, h: process.Handle) ?u64 {
    for (&p.handles, 0..) |*slot, n| {
        if (slot.* != null) continue;
        slot.* = h;
        return n;
    }
    return null; // too many open handles
}

/// A buffer from the user. It has to be memory the program can really use
/// (mapped, user, writable if the kernel writes into it), checked in its page
/// tables; a bad pointer makes the syscall fail instead of crashing the kernel.
fn userSlice(ptr: u64, len: u64, kernel_writes: bool) ?[]u8 {
    if (len > 4096) return null;
    if (!paging.userCanAccess(thread.addressSpace(), ptr, len, kernel_writes)) return null;
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}
