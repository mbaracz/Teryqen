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
    if (std.mem.indexOfScalar(u8, line, '|') != null) return runPipeline(line);
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const command = words.next().?;

    if (std.mem.eql(u8, command, "help")) {
        sys.print("built in: help, echo <text> [> file], cd <dir>, pwd, sync\nprograms: ls, cat, wc, mkdir, rm, sleep, uptime, hello\na | b runs both, a's output goes to b; > file and < file work too\nfiles in /data are kept after sync\n");
        return;
    }
    if (std.mem.eql(u8, command, "sync")) {
        if (sys.sync()) |n| sys.printf("saved {d} files from /data\n", .{n}) else sys.print("sync failed\n");
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

    const pid = startProgram(line, null, null) orelse return;
    const code = sys.wait(pid);
    if (code != 0) sys.printf("{s} exited with {d}\n", .{ command, code });
}

/// Starts one program from a piece of the line like "ls /bin > list" or
/// "wc < notes": "> file" and "< file" become its stdout/stdin, the other
/// words are its command line. `stdin`/`stdout` come from a pipe, or null.
fn startProgram(stage: []const u8, stdin: ?u64, stdout: ?u64) ?u64 {
    var cmdline_buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&cmdline_buf);
    w.writeAll("/bin/") catch {}; // "/bin", so it works from any directory
    var in = stdin;
    var out = stdout;
    var opened: [2]?u64 = .{ null, null }; // closed again once it's started
    defer for (opened) |fd| if (fd) |f| sys.close(f);

    var words = std.mem.tokenizeScalar(u8, stage, ' ');
    var first = true;
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, ">") or std.mem.eql(u8, word, "<")) {
            const writing = word[0] == '>';
            const path = words.next() orelse {
                sys.print("missing file name after > or <\n");
                return null;
            };
            const fd = sys.open(path, if (writing) .create else .read) orelse {
                sys.printf("can't open {s}\n", .{path});
                return null;
            };
            if (writing) {
                out = fd;
                opened[0] = fd;
            } else {
                in = fd;
                opened[1] = fd;
            }
            continue;
        }
        if (!first) w.writeAll(" ") catch {};
        w.writeAll(word) catch {
            sys.print("line too long\n");
            return null;
        };
        first = false;
    }
    if (first) return null; // nothing to run
    return sys.spawnWith(w.buffered(), in, out) orelse {
        sys.printf("{s}: not found\n", .{w.buffered()[5..]});
        return null;
    };
}

// ls /bin | wc: every program's stdout goes into a pipe that is the next
// one's stdin. Only programs, no built-ins here.
fn runPipeline(line: []const u8) void {
    var pids: [8]u64 = undefined;
    var count: usize = 0;
    var prev_read: ?u64 = null; // stdin for the next program
    var stages = std.mem.splitScalar(u8, line, '|');
    while (stages.next()) |stage_untrimmed| {
        const stage = std.mem.trim(u8, stage_untrimmed, " ");
        const last = stages.peek() == null;
        var out: ?sys.Pipe = null;
        if (!last) out = sys.pipe() orelse {
            sys.print("can't make a pipe\n");
            break;
        };
        const pid = startProgram(stage, prev_read, if (out) |o| o.write else null);
        // the programs have their own copies of the pipe ends now; if the
        // shell kept them, the reader would never see the end of the input
        if (prev_read) |fd| sys.close(fd);
        if (out) |o| sys.close(o.write);
        prev_read = if (out) |o| o.read else null;
        if (pid) |p| {
            if (count < pids.len) {
                pids[count] = p;
                count += 1;
            }
        }
    }
    if (prev_read) |fd| sys.close(fd);
    for (pids[0..count]) |pid| _ = sys.wait(pid);
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
