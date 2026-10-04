// System calls for user programs. Same numbers as kernel/syscall.zig.

const std = @import("std");

pub const stdin = 0;
pub const stdout = 1;

pub fn exit(code: u64) noreturn {
    _ = syscall(0, code, 0, 0);
    unreachable;
}

/// Writes to the console.
pub fn print(text: []const u8) void {
    _ = write(stdout, text);
}

pub fn printf(comptime format: []const u8, values: anytype) void {
    var buf: [256]u8 = undefined;
    print(std.fmt.bufPrint(&buf, format, values) catch "(too long)\n");
}

pub fn write(fd: u64, data: []const u8) ?usize {
    return result(syscall(1, fd, @intFromPtr(data.ptr), data.len));
}

pub fn yield() void {
    _ = syscall(2, 0, 0, 0);
}

/// From a file, or from the keyboard (stdin): waits until at least one key
/// was typed. 0 = end of file.
pub fn read(fd: u64, buf: []u8) ?usize {
    return result(syscall(3, fd, @intFromPtr(buf.ptr), buf.len));
}

/// Starts a program: "bin/cat etc/motd". Returns its pid.
pub fn spawn(cmdline: []const u8) ?u64 {
    return result(syscall(4, @intFromPtr(cmdline.ptr), cmdline.len, 0));
}

/// Waits until the program ends, returns its exit code.
pub fn wait(pid: u64) u64 {
    return syscall(5, pid, 0, 0);
}

pub const Mode = enum(u64) { read = 0, create = 1 };

pub fn open(path: []const u8, mode: Mode) ?u64 {
    return result(syscall(6, @intFromPtr(path.ptr), path.len, @intFromEnum(mode)));
}

pub fn close(fd: u64) void {
    _ = syscall(7, fd, 0, 0);
}

/// Names in a directory, one per line, directories end with "/".
pub fn readdir(fd: u64, buf: []u8) ?usize {
    return result(syscall(8, fd, @intFromPtr(buf.ptr), buf.len));
}

/// The command line the program was started with, words after the first.
pub fn args(buf: []u8) []const u8 {
    const n = syscall(9, @intFromPtr(buf.ptr), buf.len, 0);
    const line = buf[0..@min(n, buf.len)];
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return "";
    return std.mem.trim(u8, line[space..], " ");
}

const failed = std.math.maxInt(u64);

fn result(value: u64) ?u64 {
    return if (value == failed) null else value;
}

fn syscall(number: u64, a: u64, b: u64, c: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (number),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

/// Start code for every program: the kernel jumps here with rsp at the top
/// of the stack. `call` so main gets the stack alignment it expects.
pub fn start(comptime main: fn () void) void {
    const S = struct {
        fn entry() callconv(.naked) noreturn {
            asm volatile (
                \\xorl %%ebp, %%ebp
                \\callq %[run:P]
                \\ud2
                :
                : [run] "X" (&run),
            );
        }
        fn run() callconv(.c) noreturn {
            main();
            exit(0);
        }
    };
    @export(&S.entry, .{ .name = "_start" });
}

pub fn panic(msg: []const u8, _: ?usize) noreturn {
    print("panic: ");
    print(msg);
    print("\n");
    exit(255);
}
