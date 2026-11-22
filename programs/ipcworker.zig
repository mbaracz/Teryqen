// ipcworker: started by ipcdemo with a channel as handle 2. Gets a message
// and a handle, prints through that handle, replies.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var buf: [128]u8 = undefined;
    var handles: [4]u64 = undefined;
    const msg = sys.recv(sys.extra_handle, &buf, &handles) catch sys.exit(1);
    if (msg.handles.len != 1) sys.exit(2);
    var line: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "ipcworker: got \"{s}\", printing with the handle I got\n", .{msg.bytes}) catch sys.exit(3);
    _ = sys.write(msg.handles[0], text) orelse sys.exit(4);
    sys.send(sys.extra_handle, "thanks!", &.{}) catch sys.exit(5);
}
