// PS/2 keyboard. Key presses come in as an interrupt (IRQ 1 through the
// I/O APIC, vector 33). If there's no I/O APIC, a thread checks the
// controller every tick instead, like it did before.
//
// The controller translates to scancode set 1: one byte per key press, the
// same byte + 0x80 on release. US layout.

const std = @import("std");
const cpu = @import("cpu.zig");
const thread = @import("thread.zig");
const timer = @import("timer.zig");
const ioapic = @import("ioapic.zig");
const console = @import("console.zig");
const process = @import("process.zig");

const log = std.log.scoped(.keyboard);

pub const vector = 33;

const CTRL_C = 3;
const CTRL_D = 4;

const DATA = 0x60;
const STATUS = 0x64;

const normal = "\x00\x1b1234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const shifted = "\x00\x1b!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

const CTRL = 0x1d;
const LEFT_SHIFT = 0x2a;
const RIGHT_SHIFT = 0x36;
const CAPS_LOCK = 0x3a;

var shift = false;
var ctrl = false;
var caps = false;
var extended = false;

/// One byte from the keyboard -> the character it types, if any.
fn decode(byte: u8) ?u8 {
    if (byte == 0xe0) {
        // arrows etc. start with 0xe0, ignore them for now
        extended = true;
        return null;
    }
    if (extended) {
        extended = false;
        return null;
    }
    const pressed = byte & 0x80 == 0;
    const key = byte & 0x7f;
    switch (key) {
        LEFT_SHIFT, RIGHT_SHIFT => {
            shift = pressed;
            return null;
        },
        CTRL => {
            ctrl = pressed;
            return null;
        },
        CAPS_LOCK => {
            if (pressed) caps = !caps;
            return null;
        },
        else => {},
    }
    if (!pressed or key >= normal.len or normal[key] == 0) return null;
    const c = normal[key];
    if (std.ascii.isAlphabetic(c)) {
        if (ctrl) return c - 'a' + 1; // Ctrl+A = 1 ... Ctrl+Z = 26
        return if (shift != caps) std.ascii.toUpper(c) else c;
    }
    return if (shift) shifted[key] else c;
}

// Keys typed, waiting for someone to read() them.
var input: [256]u8 = undefined;
var input_len: usize = 0;
var input_waiters: thread.WaitQueue = .{};

/// Turns on the keyboard interrupt in the PS/2 controller and the I/O APIC.
pub fn init() void {
    // throw away whatever the firmware left in the buffer
    while (cpu.inb(STATUS) & 1 != 0) _ = cpu.inb(DATA);
    // controller config byte: bit 0 = interrupt for the keyboard port,
    // bit 4 = keyboard clock off. Read it (command 0x20), fix, write (0x60).
    controllerCommand(0x20);
    var config = readData() orelse return log.err("PS/2 controller doesn't answer", .{});
    config |= 1 << 0;
    config &= ~@as(u8, 1 << 4);
    controllerCommand(0x60);
    waitWritable();
    cpu.outb(DATA, config);
    ioapic.route(1, vector);
    log.info("keyboard on IRQ 1", .{});
}

/// Called from the interrupt handler.
pub fn onInterrupt() void {
    while (cpu.inb(STATUS) & 1 != 0) {
        if (decode(cpu.inb(DATA))) |c| typed(c);
    }
    timer.eoi();
}

fn controllerCommand(c: u8) void {
    waitWritable();
    cpu.outb(STATUS, c);
}

fn waitWritable() void {
    var tries: u32 = 0;
    while (cpu.inb(STATUS) & 2 != 0 and tries < 100_000) : (tries += 1) {}
}

fn readData() ?u8 {
    var tries: u32 = 0;
    while (cpu.inb(STATUS) & 1 == 0) : (tries += 1) {
        if (tries == 100_000) return null;
    }
    return cpu.inb(DATA);
}

/// Thread entry for when there are no interrupts: polls the keyboard forever.
pub fn poll(_: usize) callconv(.c) noreturn {
    // throw away whatever the firmware left in the buffer
    while (cpu.inb(STATUS) & 1 != 0) _ = cpu.inb(DATA);
    while (true) {
        while (cpu.inb(STATUS) & 1 != 0) {
            if (decode(cpu.inb(DATA))) |c| typed(c);
        }
        thread.sleepTicks(1); // look again next tick
    }
}

fn typed(c: u8) void {
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    if (c == CTRL_C and process.interruptAll() > 0) {
        // stopped whatever was running (not the shell). If nothing was, the
        // shell gets the Ctrl+C and drops the line being typed.
        console.write("^C\n");
        return;
    }
    if (input_len < input.len) {
        input[input_len] = c;
        input_len += 1;
    }
    thread.wakeAll(&input_waiters);
}

/// Waits until at least one key was typed. Call with interrupts off, so
/// nothing can sneak in between the check and the sleep (syscalls are).
pub fn read(buf: []u8) usize {
    if (buf.len == 0) return 0;
    while (input_len == 0) {
        if (thread.wasKilled()) return 0;
        thread.sleepOn(&input_waiters);
    }
    // Ctrl+D = end of input: read() returns 0 once, and stops before it
    const eof = std.mem.indexOfScalar(u8, input[0..input_len], CTRL_D);
    if (eof == 0) {
        take(1);
        return 0;
    }
    const n = @min(buf.len, eof orelse input_len);
    @memcpy(buf[0..n], input[0..n]);
    take(n);
    return n;
}

fn take(n: usize) void {
    std.mem.copyForwards(u8, input[0 .. input_len - n], input[n..input_len]);
    input_len -= n;
}
