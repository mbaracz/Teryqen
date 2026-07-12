// Drawing on the framebuffer Limine gives us.

const limine = @import("limine.zig");
const font = @import("font.zig");

pub const Screen = struct {
    pixels: [*]u32,
    width: usize,
    height: usize,
    stride: usize, // pixels per row, can be more than width
    info: *const limine.Framebuffer,

    pub fn rgb(s: Screen, r: u8, g: u8, b: u8) u32 {
        return @as(u32, r) << @intCast(s.info.red_mask_shift) |
            @as(u32, g) << @intCast(s.info.green_mask_shift) |
            @as(u32, b) << @intCast(s.info.blue_mask_shift);
    }

    pub fn clear(s: Screen, color: u32) void {
        for (0..s.height) |y| {
            @memset(s.pixels[y * s.stride ..][0..s.width], color);
        }
    }

    pub fn putPixel(s: Screen, x: usize, y: usize, color: u32) void {
        if (x >= s.width or y >= s.height) return;
        s.pixels[y * s.stride + x] = color;
    }

    /// Draws text with every font pixel as a scale x scale square.
    pub fn drawText(s: Screen, x: usize, y: usize, text: []const u8, color: u32, scale: usize) void {
        for (text, 0..) |c, i| {
            const cx = x + i * (font.width + 1) * scale;
            for (0..font.height) |fy| {
                for (0..font.width) |fx| {
                    if (!font.pixel(c, fx, fy)) continue;
                    for (0..scale) |dy| {
                        for (0..scale) |dx| {
                            s.putPixel(cx + fx * scale + dx, y + fy * scale + dy, color);
                        }
                    }
                }
            }
        }
    }
};

/// Only 32 bits per pixel for now, that's what QEMU gives.
pub fn init(info: *const limine.Framebuffer) ?Screen {
    if (info.bpp != 32) return null;
    return .{
        .pixels = @ptrCast(@alignCast(info.address)),
        .width = info.width,
        .height = info.height,
        .stride = info.pitch / 4,
        .info = info,
    };
}
