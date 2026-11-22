// ipcdemo: talks to ipcworker over a channel. Sends it a message together
// with a handle (a copy of my stdout, so it can print), waits for the reply,
// then waits for the channel to say the worker is gone.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    const ch = sys.channel() orelse return fail("can't make a channel");
    const pid = sys.spawnFull("/bin/ipcworker", null, null, ch.b) orelse return fail("can't start ipcworker");
    sys.close(ch.b); // the worker has its own copy, I keep my end only

    const out = sys.duplicate(sys.stdout, .{ .write = true, .transfer = true }) orelse return fail("can't copy stdout");
    sys.send(ch.a, "hello worker", &.{out}) catch return fail("send failed");
    sys.print("ipcdemo: sent a message and a handle\n");

    var buf: [128]u8 = undefined;
    var handles: [4]u64 = undefined;
    const reply = sys.recv(ch.a, &buf, &handles) catch return fail("no reply");
    sys.printf("ipcdemo: worker replied \"{s}\"\n", .{reply.bytes});

    _ = sys.wait(pid);
    if (sys.recv(ch.a, &buf, &handles)) |_| {
        sys.print("ipcdemo: another message?\n");
    } else |err| {
        sys.printf("ipcdemo: after the worker exited: {s}\n", .{@errorName(err)});
    }
}

fn fail(why: []const u8) void {
    sys.printf("ipcdemo: {s}\n", .{why});
    sys.exit(1);
}
