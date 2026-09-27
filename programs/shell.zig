// The shell. Reads a line, runs bin/<first word> from the initramfs and waits
// for it. A couple of commands are built in.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    sys.write("Type help for help.\n");
    while (true) {
        sys.write("> ");
        var buf: [128]u8 = undefined;
        const line = readLine(&buf);
        run(std.mem.trim(u8, line, " "));
    }
}

fn run(line: []const u8) void {
    if (line.len == 0) return;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const command = words.next().?;

    if (std.mem.eql(u8, command, "help")) {
        sys.write("built in: help, echo <text>\nprograms: hello\n");
        return;
    }
    if (std.mem.eql(u8, command, "echo")) {
        sys.write(words.rest());
        sys.write("\n");
        return;
    }

    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "bin/{s}", .{command}) catch {
        sys.write("name too long\n");
        return;
    };
    const pid = sys.spawn(path) orelse {
        sys.write(command);
        sys.write(": not found\n");
        return;
    };
    const code = sys.wait(pid);
    if (code != 0) {
        var msg: [64]u8 = undefined;
        sys.write(std.fmt.bufPrint(&msg, "{s} exited with {d}\n", .{ command, code }) catch "failed\n");
    }
}

// Reads keys until Enter. The kernel doesn't echo, so do it here.
fn readLine(buf: []u8) []const u8 {
    var len: usize = 0;
    while (true) {
        var c: [1]u8 = undefined;
        if (sys.read(&c) == 0) continue;
        switch (c[0]) {
            '\n' => {
                sys.write("\n");
                return buf[0..len];
            },
            0x08 => if (len > 0) {
                len -= 1;
                sys.write(&c);
            },
            else => if (len < buf.len and c[0] >= ' ') {
                buf[len] = c[0];
                len += 1;
                sys.write(&c);
            },
        }
    }
}
