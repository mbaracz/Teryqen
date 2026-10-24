// sleep <seconds>: waits. Seconds can have a fraction, like 0.5.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var args_buf: [128]u8 = undefined;
    const arg = sys.args(&args_buf);
    const ms = parseMs(arg) orelse {
        sys.print("usage: sleep <seconds>\n");
        sys.exit(1);
    };
    sys.sleep(ms);
}

// no floats in here (no SSE), so do it by hand: "1.25" -> 1250
fn parseMs(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    const seconds = if (dot == 0) 0 else std.fmt.parseInt(u64, text[0..dot], 10) catch return null;
    var ms = seconds * 1000;
    if (dot < text.len) {
        var scale: u64 = 100;
        for (text[dot + 1 ..]) |ch| {
            if (!std.ascii.isDigit(ch)) return null;
            ms += (ch - '0') * scale;
            scale /= 10;
        }
    }
    return ms;
}
