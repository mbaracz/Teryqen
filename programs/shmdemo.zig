// shmdemo: shares a page with shmworker. Writes into it, sends the handle
// over a channel, the worker changes the page, and the change shows up here
// without anything being copied.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    const mem = sys.memoryCreate(4096) orelse return fail("can't make memory");
    const page = sys.memoryMap(mem, 4096, true) orelse return fail("can't map it");
    const hello = "hello from shmdemo";
    @memcpy(page[0..hello.len], hello);

    const ch = sys.channel() orelse return fail("can't make a channel");
    const pid = sys.spawnFull("/bin/shmworker", null, null, ch.b) orelse return fail("can't start shmworker");
    sys.close(ch.b);
    sys.send(ch.a, "", &.{mem}) catch return fail("send failed"); // the handle goes to the worker

    var buf: [16]u8 = undefined;
    var handles: [1]u64 = undefined;
    _ = sys.recv(ch.a, &buf, &handles) catch return fail("no answer");
    sys.printf("shmdemo: the page says \"{s}\" now\n", .{std.mem.sliceTo(page, 0)});
    _ = sys.wait(pid);
    sys.memoryUnmap(page);
}

fn fail(why: []const u8) void {
    sys.printf("shmdemo: {s}\n", .{why});
    sys.exit(1);
}
