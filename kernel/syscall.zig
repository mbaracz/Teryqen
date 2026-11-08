// User mode (ring 3) and system calls.
//
// A user program calls the kernel with the `syscall` instruction:
//   rax = number, rdi/rsi/rdx = arguments, result comes back in rax
//   (all ones = error).
//   0 exit(code)            1 write(fd, ptr, len)   2 yield()
//   3 read(fd, ptr, len)    4 spawn(ptr, len, fds)  5 wait(pid)
//   6 open(ptr, len, flags) 7 close(fd)             8 readdir(fd, ptr, len)
//   9 args(ptr, len)        10 mkdir(ptr, len)      11 remove(ptr, len)
//  12 chdir(ptr, len)      13 getcwd(ptr, len)     14 sync()
//  15 sleep(ms)            16 uptime() -> ms       17 pipe() -> fds
// Paths can be relative to the current directory.
// fd 0 is stdin, fd 1 stdout (the keyboard and the console, unless the
// program was started with a pipe there). open() with flags 1 creates the
// file (or empties it) for writing. pipe() returns read fd | write fd << 32,
// spawn's `fds` is (stdin fd + 1) | (stdout fd + 1) << 16, 0 = keep mine.
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
    const p = process.current();
    switch (number) {
        0 => {
            log.debug("thread {d}: program exited with {d}", .{ thread.currentId(), a });
            process.exit(a);
        },
        1 => {
            const data = userSlice(b, c, false) orelse return failed;
            const fd = getFd(p, a) orelse return failed;
            switch (fd.*) {
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
            const fd = getFd(p, a) orelse return failed;
            switch (fd.*) {
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
            const stdin: ?process.Fd = if (in_fd == 0) null else (getFd(p, in_fd - 1) orelse return failed).*;
            const stdout: ?process.Fd = if (out_fd == 0) null else (getFd(p, out_fd - 1) orelse return failed).*;
            return process.spawn(cmdline, stdin, stdout) orelse failed;
        },
        5 => return process.wait(a),
        6 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b, false) orelse return failed, &buf) orelse return failed;
            const node = (if (c == 1) fs.create(path, false) else fs.lookup(path)) catch return failed;
            return addFd(p, .{ .file = .{ .node = node } }) orelse failed;
        },
        7 => {
            const fd = getFd(p, a) orelse return failed;
            fd.close();
            p.files[a] = null;
            return 0;
        },
        8 => {
            // names of everything in the directory, one per line, "/" after
            // directories
            const buf = userSlice(b, c, true) orelse return failed;
            const fd = getFd(p, a) orelse return failed;
            if (fd.* != .file or !fd.file.node.is_dir) return failed;
            const file = &fd.file;
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
            const r = addFd(p, .{ .pipe_read = pipe }) orelse {
                pipe.close(false);
                pipe.close(true);
                return failed;
            };
            const w = addFd(p, .{ .pipe_write = pipe }) orelse {
                p.files[r] = null;
                pipe.close(false);
                pipe.close(true);
                return failed;
            };
            return r | (w << 32);
        },
        else => return failed,
    }
}

fn getFd(p: *process.Process, fd: u64) ?*process.Fd {
    if (fd >= p.files.len) return null;
    if (p.files[fd]) |*f| return f;
    return null;
}

fn addFd(p: *process.Process, fd: process.Fd) ?u64 {
    for (&p.files, 0..) |*slot, n| {
        if (slot.* != null) continue;
        slot.* = fd;
        return n;
    }
    return null; // too many open files
}

/// A buffer from the user. It has to be memory the program can really use
/// (mapped, user, writable if the kernel writes into it), checked in its page
/// tables; a bad pointer makes the syscall fail instead of crashing the kernel.
fn userSlice(ptr: u64, len: u64, kernel_writes: bool) ?[]u8 {
    if (len > 4096) return null;
    if (!paging.userCanAccess(thread.addressSpace(), ptr, len, kernel_writes)) return null;
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}
