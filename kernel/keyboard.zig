// PS/2 keyboard. No interrupts yet (that needs the I/O APIC, which needs
// ACPI...), so a thread just checks the controller every tick.
//
// The controller translates to scancode set 1: one byte per key press, the
// same byte + 0x80 on release. US layout.

const std = @import("std");
const cpu = @import("cpu.zig");
const thread = @import("thread.zig");

const DATA = 0x60;
const STATUS = 0x64;

const normal = "\x00\x1b1234567890-=\x08\tqwertyuiop[]\n\x00asdfghjkl;'`\x00\\zxcvbnm,./\x00*\x00 ";
const shifted = "\x00\x1b!@#$%^&*()_+\x08\tQWERTYUIOP{}\n\x00ASDFGHJKL:\"~\x00|ZXCVBNM<>?\x00*\x00 ";

const LEFT_SHIFT = 0x2a;
const RIGHT_SHIFT = 0x36;
const CAPS_LOCK = 0x3a;

var shift = false;
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
        CAPS_LOCK => {
            if (pressed) caps = !caps;
            return null;
        },
        else => {},
    }
    if (!pressed or key >= normal.len or normal[key] == 0) return null;
    const c = normal[key];
    if (std.ascii.isAlphabetic(c)) {
        return if (shift != caps) std.ascii.toUpper(c) else c;
    }
    return if (shift) shifted[key] else c;
}

// Keys typed, waiting for someone to read() them.
var input: [256]u8 = undefined;
var input_len: usize = 0;
var input_waiters: thread.WaitQueue = .{};

/// Thread entry: polls the keyboard forever and keeps what's typed for read().
pub fn run(_: usize) callconv(.c) noreturn {
    // throw away whatever the firmware left in the buffer
    while (cpu.inb(STATUS) & 1 != 0) _ = cpu.inb(DATA);
    while (true) {
        while (cpu.inb(STATUS) & 1 != 0) {
            if (decode(cpu.inb(DATA))) |c| typed(c);
        }
        thread.yield();
        asm volatile ("hlt"); // next tick
    }
}

fn typed(c: u8) void {
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
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
    while (input_len == 0) thread.sleepOn(&input_waiters);
    const n = @min(buf.len, input_len);
    @memcpy(buf[0..n], input[0..n]);
    std.mem.copyForwards(u8, input[0 .. input_len - n], input[n..input_len]);
    input_len -= n;
    return n;
}
