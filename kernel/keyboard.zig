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

/// Thread entry: polls the keyboard forever and calls on_key(arg) for
/// every character typed.
pub fn run(on_key: usize) callconv(.c) noreturn {
    const callback: *const fn (u8) void = @ptrFromInt(on_key);
    // throw away whatever the firmware left in the buffer
    while (cpu.inb(STATUS) & 1 != 0) _ = cpu.inb(DATA);
    while (true) {
        while (cpu.inb(STATUS) & 1 != 0) {
            if (decode(cpu.inb(DATA))) |c| callback(c);
        }
        thread.yield();
        asm volatile ("hlt"); // next tick
    }
}
