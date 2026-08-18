// COM1 serial port. QEMU shows it in the terminal with -serial stdio.
// No interrupts, just wait until the UART is ready and write the byte.

const cpu = @import("cpu.zig");
const outb = cpu.outb;
const inb = cpu.inb;

const com1: u16 = 0x3f8;

pub fn init() void {
    outb(com1 + 1, 0x00); // interrupts off
    outb(com1 + 3, 0x80); // enable divisor
    outb(com1 + 0, 0x01); // 115200 baud
    outb(com1 + 1, 0x00);
    outb(com1 + 3, 0x03); // 8 bits, no parity, 1 stop bit
    outb(com1 + 2, 0xc7); // FIFO on
    outb(com1 + 4, 0x03);
}

fn writeByte(byte: u8) void {
    // wait for "transmit empty", but don't hang forever if there's no UART
    var tries: u32 = 0;
    while (inb(com1 + 5) & 0x20 == 0) : (tries += 1) {
        if (tries == 100_000) return;
    }
    outb(com1, byte);
}

pub fn write(text: []const u8) void {
    for (text) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}
