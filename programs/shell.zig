// The shell. Reads a line, runs bin/<first word> with the rest of the line
// as its arguments and waits for it. A couple of commands are built in.

const std = @import("std");
const sys = @import("sys.zig");

comptime {
    sys.start(main);
}

pub const panic = std.debug.FullPanic(sys.panic);

fn main() void {
    sys.print("Type help for help.\n");
    while (true) {
        var cwd_buf: [128]u8 = undefined;
        sys.printf("{s}> ", .{sys.getcwd(&cwd_buf)});
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
        sys.print("built in: help, echo <text> [> file], cd <dir>, pwd\nprograms: ls, cat, mkdir, rm, hello\n");
        return;
    }
    if (std.mem.eql(u8, command, "cd")) {
        const dir = words.next() orelse "/";
        if (!sys.chdir(dir)) sys.printf("cd: {s}: no such directory\n", .{dir});
        return;
    }
    if (std.mem.eql(u8, command, "pwd")) {
        var cwd_buf: [128]u8 = undefined;
        sys.printf("{s}\n", .{sys.getcwd(&cwd_buf)});
        return;
    }
    if (std.mem.eql(u8, command, "echo")) return echo(words.rest());

    var cmdline_buf: [128]u8 = undefined;
    // "/bin", so it works from any directory
    const cmdline = std.fmt.bufPrint(&cmdline_buf, "/bin/{s}", .{line}) catch {
        sys.print("line too long\n");
        return;
    };
    const pid = sys.spawn(cmdline) orelse {
        sys.printf("{s}: not found\n", .{command});
        return;
    };
    const code = sys.wait(pid);
    if (code != 0) sys.printf("{s} exited with {d}\n", .{ command, code });
}

// echo some text
// echo some text > file
fn echo(text: []const u8) void {
    const arrow = std.mem.indexOfScalar(u8, text, '>') orelse {
        sys.print(text);
        sys.print("\n");
        return;
    };
    const path = std.mem.trim(u8, text[arrow + 1 ..], " ");
    const fd = sys.open(path, .create) orelse {
        sys.printf("can't write {s}\n", .{path});
        return;
    };
    defer sys.close(fd);
    _ = sys.write(fd, std.mem.trim(u8, text[0..arrow], " "));
    _ = sys.write(fd, "\n");
}

// Reads keys until Enter. The kernel doesn't echo, so do it here.
fn readLine(buf: []u8) []const u8 {
    var len: usize = 0;
    while (true) {
        var c: [1]u8 = undefined;
        if ((sys.read(sys.stdin, &c) orelse 0) == 0) continue;
        switch (c[0]) {
            '\n' => {
                sys.print("\n");
                return buf[0..len];
            },
            0x08 => if (len > 0) {
                len -= 1;
                sys.print(&c);
            },
            else => if (len < buf.len and c[0] >= ' ') {
                buf[len] = c[0];
                len += 1;
                sys.print(&c);
            },
        }
    }
}
