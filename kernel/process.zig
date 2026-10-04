// User programs: loading one into its own address space, its open files,
// exit and wait. The pid is just the index in the table.

const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const thread = @import("thread.zig");
const elf = @import("elf.zig");
const fs = @import("fs.zig");

const log = std.log.scoped(.process);

const stack_top: u64 = 0x7fff_ffff_f000;
const stack_pages = 4; // 16 KiB, std.fmt in Debug mode wants quite a bit

pub const failed = std.math.maxInt(u64);

/// An open file: fd 0 is the keyboard and fd 1 the console, files start at 2.
pub const File = struct {
    node: *fs.Node,
    pos: usize = 0,
};

pub const Process = struct {
    used: bool = false,
    done: bool = false,
    exit_code: u64 = 0,
    waiters: thread.WaitQueue = .{}, // threads in wait() for this one
    // the whole command line, "bin/cat /etc/motd"; the program asks for it
    // with the args syscall
    cmdline: [128]u8 = undefined,
    cmdline_len: usize = 0,
    files: [8]?File = @splat(null),

    pub fn args(p: *const Process) []const u8 {
        return p.cmdline[0..p.cmdline_len];
    }
};
var processes: [16]Process = @splat(.{});

/// The process of the calling thread (only call from a user program's thread).
pub fn current() *Process {
    return @ptrFromInt(thread.process());
}

/// Starts the program named by the first word of `cmdline`. Returns its pid.
pub fn spawn(cmdline: []const u8) ?u64 {
    if (cmdline.len > 128) return null;
    var words = std.mem.tokenizeScalar(u8, cmdline, ' ');
    const path = words.next() orelse return null;
    const file = fs.lookup(path) catch return null;
    if (file.is_dir) return null;
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    for (&processes, 0..) |*p, pid| {
        if (p.used) continue;
        // copy it: the caller's memory isn't visible from the new thread
        p.* = .{ .used = true, .cmdline_len = cmdline.len };
        @memcpy(p.cmdline[0..cmdline.len], cmdline);
        _ = thread.spawn(run, @intFromPtr(p)) catch {
            p.used = false;
            return null;
        };
        return pid;
    }
    return null; // table full
}

/// Waits for the program to end, returns its exit code.
pub fn wait(pid: u64) u64 {
    if (pid >= processes.len or !processes[pid].used) return failed;
    const p = &processes[pid];
    while (!p.done) thread.sleepOn(&p.waiters);
    p.used = false;
    return p.exit_code;
}

/// Thread entry: load the program into a new address space, give it a
/// stack, then drop to ring 3. `arg` is its *Process.
fn run(arg: usize) callconv(.c) noreturn {
    const p: *Process = @ptrFromInt(arg);
    thread.setProcess(arg);
    var words = std.mem.tokenizeScalar(u8, p.args(), ' ');
    const path = words.next().?;
    const space = paging.newAddressSpace();
    thread.setAddressSpace(space);
    const file = fs.lookup(path) catch {
        log.err("thread {d}: {s} is gone", .{ thread.currentId(), path });
        exit(failed);
    };
    const entry = elf.load(space, file.data.items) catch |err| {
        log.err("thread {d}: can't load {s}: {s}", .{ thread.currentId(), path, @errorName(err) });
        exit(failed);
    };
    for (1..stack_pages + 1) |i| {
        const frame = pmm.alloc() orelse @panic("no memory for the user stack");
        @memset(pmm.toVirt([4096]u8, frame), 0);
        paging.mapIn(space, stack_top - i * 4096, frame, paging.USER | paging.WRITABLE | paging.NO_EXECUTE);
    }

    log.debug("thread {d}: {s} entering ring 3 at 0x{x}", .{ thread.currentId(), path, entry });
    // iretq pops rip, cs, rflags, rsp, ss. Interrupts on (0x202) in user mode.
    asm volatile (
        \\pushq %[ss]
        \\pushq %[rsp]
        \\pushq $0x202
        \\pushq %[cs]
        \\pushq %[rip]
        \\iretq
        :
        : [ss] "r" (@as(u64, gdt.user_data)),
          [rsp] "r" (stack_top),
          [cs] "r" (@as(u64, gdt.user_code)),
          [rip] "r" (entry),
    );
    unreachable;
}

/// The program is done (exit or crash): tell whoever waits, free its whole
/// address space, end the thread.
pub fn exit(code: u64) noreturn {
    if (thread.process() != 0) {
        const p = current();
        p.files = @splat(null);
        p.exit_code = code;
        p.done = true;
        thread.wakeAll(&p.waiters);
    }
    const space = thread.addressSpace();
    thread.setAddressSpace(0); // can't free the page tables we're running on
    paging.freeAddressSpace(space);
    thread.exit();
}
