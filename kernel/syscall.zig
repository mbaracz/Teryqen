// User mode (ring 3) and system calls.
//
// A user program calls the kernel with the `syscall` instruction:
//   rax = number, rdi/rsi/rdx = arguments, result comes back in rax
//   (all ones = error).
//   0 exit(code)            1 write(fd, ptr, len)   2 yield()
//   3 read(fd, ptr, len)    4 spawn(ptr, len)       5 wait(pid)
//   6 open(ptr, len, flags) 7 close(fd)             8 readdir(fd, ptr, len)
//   9 args(ptr, len)        10 mkdir(ptr, len)      11 remove(ptr, len)
//  12 chdir(ptr, len)      13 getcwd(ptr, len)
// Paths can be relative to the current directory.
// fd 0 is the keyboard, fd 1 the console. open() with flags 1 creates the
// file (or empties it) for writing.
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
const heap = @import("heap.zig");

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
            const data = userSlice(b, c) orelse return failed;
            if (a == 1) {
                serial.write(data);
                if (console_ready) console.write(data);
                return data.len;
            }
            const file = openFile(p, a) orelse return failed;
            if (file.node.is_dir) return failed;
            // writing past the end makes the file longer
            const end = file.pos + data.len;
            if (end > file.node.data.items.len) file.node.data.resize(heap.allocator, end) catch return failed;
            @memcpy(file.node.data.items[file.pos..end], data);
            file.pos = end;
            return data.len;
        },
        2 => {
            thread.yield();
            return 0;
        },
        3 => {
            const buf = userSlice(b, c) orelse return failed;
            if (a == 0) return keyboard.read(buf);
            const file = openFile(p, a) orelse return failed;
            if (file.node.is_dir) return failed;
            const left = file.node.data.items[@min(file.pos, file.node.data.items.len)..];
            const n = @min(buf.len, left.len);
            @memcpy(buf[0..n], left[0..n]);
            file.pos += n;
            return n;
        },
        4 => {
            const cmdline = userSlice(a, b) orelse return failed;
            return process.spawn(cmdline) orelse failed;
        },
        5 => return process.wait(a),
        6 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b) orelse return failed, &buf) orelse return failed;
            const node = (if (c == 1) fs.create(path, false) else fs.lookup(path)) catch return failed;
            for (p.files[2..], 2..) |*slot, fd| {
                if (slot.* != null) continue;
                slot.* = .{ .node = node };
                return fd;
            }
            return failed; // too many open files
        },
        7 => {
            if (a < 2 or a >= p.files.len) return failed;
            p.files[a] = null;
            return 0;
        },
        8 => {
            // names of everything in the directory, one per line, "/" after
            // directories
            const buf = userSlice(b, c) orelse return failed;
            const file = openFile(p, a) orelse return failed;
            if (!file.node.is_dir) return failed;
            var w: std.Io.Writer = .fixed(buf);
            for (file.node.children.items) |child| {
                w.print("{s}{s}\n", .{ child.getName(), if (child.is_dir) "/" else "" }) catch break;
            }
            return w.end;
        },
        9 => {
            const buf = userSlice(a, b) orelse return failed;
            const n = @min(buf.len, p.args().len);
            @memcpy(buf[0..n], p.args()[0..n]);
            return n;
        },
        10 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b) orelse return failed, &buf) orelse return failed;
            _ = fs.mkdir(path) catch return failed;
            return 0;
        },
        11 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b) orelse return failed, &buf) orelse return failed;
            const node = fs.lookup(path) catch return failed;
            // someone still using it would be left with a pointer to freed memory
            if (process.isOpen(node)) return failed;
            fs.remove(path) catch return failed;
            return 0;
        },
        12 => {
            var buf: [256]u8 = undefined;
            const path = p.resolve(userSlice(a, b) orelse return failed, &buf) orelse return failed;
            const node = fs.lookup(path) catch return failed;
            if (!node.is_dir or path.len > p.cwd.len) return failed;
            @memcpy(p.cwd[0..path.len], path);
            p.cwd_len = path.len;
            return 0;
        },
        13 => {
            const out = userSlice(a, b) orelse return failed;
            const n = @min(out.len, p.cwd_len);
            @memcpy(out[0..n], p.getCwd()[0..n]);
            return n;
        },
        else => return failed,
    }
}

fn openFile(p: *process.Process, fd: u64) ?*process.File {
    if (fd < 2 or fd >= p.files.len) return null;
    if (p.files[fd]) |*file| return file;
    return null;
}

/// The pointer comes from the user, it has to point into user memory.
fn userSlice(ptr: u64, len: u64) ?[]u8 {
    if (ptr >= user_end or len > 4096 or ptr + len > user_end) return null;
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}

const user_end: u64 = 0x8000_0000_0000;
