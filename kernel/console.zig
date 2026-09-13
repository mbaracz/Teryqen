// Text console on the framebuffer: a grid of characters with a cursor.
// Handles newline, backspace and scrolls when it reaches the bottom.

const fb = @import("fb.zig");
const cpu = @import("cpu.zig");
const font = @import("font.zig");

const scale = 2;
const cell_w = (font.width + 1) * scale;
const cell_h = (font.height + 3) * scale;

var screen: fb.Screen = undefined;
var top: usize = 0; // y where the console starts, above it is the title
var cols: usize = 0;
var rows: usize = 0;
var col: usize = 0;
var row: usize = 0;
var fg: u32 = 0;
var bg: u32 = 0;

pub fn init(s: fb.Screen, y: usize) void {
    screen = s;
    top = y;
    cols = (s.width - 2 * 32) / cell_w;
    rows = (s.height - y - 32) / cell_h;
    fg = s.rgb(0xe6, 0xe8, 0xee);
    bg = s.rgb(0x1c, 0x1f, 0x26);
    drawCursor(fg);
}

pub fn write(text: []const u8) void {
    // keyboard thread and user programs both write here
    const irq = cpu.disableInterrupts();
    defer cpu.restoreInterrupts(irq);
    drawCursor(bg);
    for (text) |c| put(c);
    drawCursor(fg);
}

fn put(c: u8) void {
    switch (c) {
        '\n' => newLine(),
        0x08 => { // backspace
            if (col == 0) return;
            col -= 1;
            clearCell(col, row);
        },
        else => {
            clearCell(col, row);
            screen.drawText(cellX(col), cellY(row), &.{c}, fg, scale);
            col += 1;
            if (col == cols) newLine();
        },
    }
}

fn newLine() void {
    col = 0;
    if (row + 1 < rows) {
        row += 1;
        return;
    }
    // scroll: move every pixel row of the console up by one text line
    const first = top;
    const last = top + rows * cell_h;
    for (first..last - cell_h) |y| {
        const dst = screen.pixels[y * screen.stride ..][0..screen.width];
        const src = screen.pixels[(y + cell_h) * screen.stride ..][0..screen.width];
        @memcpy(dst, src);
    }
    screen.fillRect(0, last - cell_h, screen.width, cell_h, bg);
}

fn cellX(c: usize) usize {
    return 32 + c * cell_w;
}

fn cellY(r: usize) usize {
    return top + r * cell_h;
}

fn clearCell(c: usize, r: usize) void {
    screen.fillRect(cellX(c), cellY(r), cell_w, cell_h, bg);
}

// underline cursor
fn drawCursor(color: u32) void {
    screen.fillRect(cellX(col), cellY(row) + font.height * scale + 2, cell_w - scale, scale, color);
}
