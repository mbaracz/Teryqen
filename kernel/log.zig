// std.log goes to the serial port, so I can use log.info("{d}", ...)
// instead of building strings by hand for serial.write.

const std = @import("std");
const serial = @import("serial.zig");

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = comptime level.asText() ++ "(" ++ @tagName(scope) ++ "): ";
    // no allocator in the kernel, so format into a buffer on the stack
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print(prefix ++ format ++ "\n", args) catch {
        // too long, print what fits
        serial.write(w.buffered());
        serial.write("...\n");
        return;
    };
    serial.write(w.buffered());
}
