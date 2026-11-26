// shmworker: gets a memory object from shmdemo (channel = handle 2), maps
// it, reads what's there and writes something back.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    var buf: [16]u8 = undefined;
    var handles: [1]u64 = undefined;
    const msg = sys.recv(sys.extra_handle, &buf, &handles) catch sys.exit(1);
    if (msg.handles.len != 1) sys.exit(2);
    const page = sys.memoryMap(msg.handles[0], 4096, true) orelse sys.exit(3);
    sys.printf("shmworker: the page says \"{s}\"\n", .{std.mem.sliceTo(page, 0)});
    const reply = "and hi from shmworker";
    @memcpy(page[0 .. reply.len + 1], reply ++ "\x00");
    sys.send(sys.extra_handle, "done", &.{}) catch sys.exit(4);
}
