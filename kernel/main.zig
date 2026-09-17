const std = @import("std");
const serial = @import("serial.zig");
const limine = @import("limine.zig");
const fb = @import("fb.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const heap = @import("heap.zig");
const timer = @import("timer.zig");
const thread = @import("thread.zig");
const console = @import("console.zig");
const keyboard = @import("keyboard.zig");
const syscall = @import("syscall.zig");

pub const std_options: std.Options = .{
    .logFn = @import("log.zig").logFn,
};

const log = std.log.scoped(.boot);

// Limine jumps here in 64-bit mode with interrupts off.
// Clear rbp (end of the stack trace), align the stack and call kmain.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\xorl %%ebp, %%ebp
        \\andq $-16, %%rsp
        \\callq kmain
        \\ud2
    );
}

export fn kmain() noreturn {
    serial.init();
    gdt.init();
    idt.init();
    syscall.init();
    if (!limine.supported()) {
        log.err("bootloader doesn't support Limine base revision 6", .{});
        hang();
    }
    serial.write("hello from teryqen!\n");

    // check that interrupts come back: int3 should land in the handler and return
    asm volatile ("int3");
    log.debug("survived int3", .{});

    pmm.init();
    // quick check: grab a few frames, write to them, give them back
    const before = pmm.freeCount();
    var frames: [16]u64 = undefined;
    for (&frames, 0..) |*f, i| {
        f.* = pmm.alloc() orelse @panic("out of memory already?");
        pmm.toVirt(u64, f.*).* = i;
    }
    for (frames, 0..) |f, i| {
        if (pmm.toVirt(u64, f).* != i) @panic("frame memory doesn't keep what I wrote");
        pmm.free(f);
    }
    if (pmm.freeCount() != before) @panic("frames got lost");
    log.debug("pmm alloc/free ok", .{});

    paging.init();
    testHeap();

    var screen: ?fb.Screen = null;
    if (limine.framebuffer()) |info| {
        log.info("framebuffer {d}x{d}", .{ info.width, info.height });
        screen = fb.init(info);
        if (screen) |s| {
            s.clear(s.rgb(0x1c, 0x1f, 0x26));
            s.drawText(32, 32, "Hello from Teryqen!", s.rgb(0xe6, 0xe8, 0xee), 4);
        } else {
            log.err("framebuffer is {d} bpp, only 32 works", .{info.bpp});
        }
    } else {
        log.warn("no framebuffer", .{});
    }

    timer.init();
    asm volatile ("sti");
    log.debug("interrupts on", .{});

    // two threads taking turns (without asking)
    _ = thread.spawn(counter, 'a') catch @panic("can't start a thread");
    _ = thread.spawn(counter, 'b') catch @panic("can't start a thread");

    if (screen) |s| {
        console.init(s, 150);
        syscall.console_ready = true;
    }
    // two copies of the same program, at the same addresses, at the same time
    _ = thread.spawn(syscall.runProgram, 0) catch @panic("can't start the user program");
    _ = thread.spawn(syscall.runProgram, 0) catch @panic("can't start the user program");
    while (timer.ticksSinceBoot() < 50) thread.yield(); // let it finish first
    if (screen != null) console.write("Type something:\n> ");
    _ = thread.spawn(keyboard.run, @intFromPtr(&onKey)) catch @panic("can't start the keyboard thread");

    // nothing to do yet: sleep until the next interrupt, show the uptime once a second
    var shown: u64 = 0;
    while (true) {
        thread.yield();
        asm volatile ("hlt");
        const seconds = timer.ticksSinceBoot() / timer.hz;
        if (seconds == shown) continue;
        shown = seconds;
        if (seconds == 1) log.debug("1 second of ticks, timer works", .{});
        if (screen) |s| {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "up {d}s", .{seconds}) catch continue;
            s.fillRect(32, 100, 400, 16, s.rgb(0x1c, 0x1f, 0x26)); // erase the old number
            s.drawText(32, 100, text, s.rgb(0x8a, 0x90, 0x9c), 2);
        }
    }
}

var line: [128]u8 = undefined;
var line_len: usize = 0;

// Every key typed: show it, and on Enter log the whole line to serial.
fn onKey(c: u8) void {
    switch (c) {
        '\n' => {
            log.info("typed: {s}", .{line[0..line_len]});
            line_len = 0;
            console.write("\n> ");
        },
        0x08 => if (line_len > 0) {
            line_len -= 1;
            console.write(&.{c});
        },
        else => if (line_len < line.len) {
            line[line_len] = c;
            line_len += 1;
            console.write(&.{c});
        },
    }
}

// Never yields, just burns CPU between prints. Both threads still take
// turns, because the timer switches them.
fn counter(name: usize) callconv(.c) noreturn {
    for (1..4) |i| {
        log.info("thread {d} ({c}): {d}", .{ thread.currentId(), @as(u8, @intCast(name)), i });
        const until = timer.ticksSinceBoot() + 10;
        while (timer.ticksSinceBoot() < until) {}
    }
    thread.exit();
}

// try out the heap with a growing list and a big buffer
fn testHeap() void {
    const free_before = pmm.freeCount();
    var list: std.ArrayList(u64) = .empty;
    for (0..10_000) |i| list.append(heap.allocator, i) catch @panic("heap: out of memory");
    var sum: u64 = 0;
    for (list.items) |x| sum += x;
    if (sum != 10_000 * 9_999 / 2) @panic("heap: list is broken");
    list.deinit(heap.allocator);

    const big = heap.allocator.alloc(u8, 100_000) catch @panic("heap: no big buffer");
    @memset(big, 0xab);
    heap.allocator.free(big);
    log.debug("heap ok, {d} frames kept (small pieces + page tables)", .{free_before - pmm.freeCount()});
}

fn hang() noreturn {
    while (true) {
        asm volatile (
            \\cli
            \\hlt
        );
    }
}

var panicking = false;

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    asm volatile ("cli");
    // if printing the backtrace itself crashes, don't loop forever
    if (panicking) {
        serial.write("PANIC inside panic: ");
        serial.write(msg);
        serial.write("\n");
        hang();
    }
    panicking = true;

    serial.write("PANIC: ");
    serial.write(msg);
    serial.write("\n");

    var buf: [64]u8 = undefined;
    if (first_trace_addr) |addr| {
        serial.write(std.fmt.bufPrint(&buf, "  at 0x{x}\n", .{addr}) catch "");
    }
    // Walk the frame pointers: every frame starts with [saved rbp, return address].
    // _start sets rbp to 0, that's where it ends.
    // Turn the addresses into function names with:
    //   addr2line -f -e zig-out/bin/kernel <address>
    var rbp = @frameAddress();
    var i: usize = 0;
    while (rbp != 0 and rbp % 8 == 0 and i < 20) : (i += 1) {
        const frame: *const [2]usize = @ptrFromInt(rbp);
        if (frame[1] == 0) break;
        serial.write(std.fmt.bufPrint(&buf, "  #{d} 0x{x}\n", .{ i, frame[1] }) catch "");
        if (frame[0] <= rbp) break; // stack goes up, anything else is garbage
        rbp = frame[0];
    }
    hang();
}

pub const panic = std.debug.FullPanic(panicHandler);
