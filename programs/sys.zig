// System calls for user programs. Same numbers as kernel/syscall.zig.

const std = @import("std");

// Handles: small numbers naming something the kernel keeps for this program
// (keyboard, console, a file, a pipe end), each with rights.
pub const stdin = 0;
pub const stdout = 1;

pub const Rights = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    duplicate: bool = false,
    transfer: bool = false,
    _: u4 = 0,
};

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

/// Starts a program: "bin/cat etc/motd". Returns its pid. It gets my stdin
/// and stdout.
pub fn spawn(cmdline: []const u8) ?u64 {
    return spawnWith(cmdline, null, null);
}

/// Same, but with other handles as its stdin/stdout (null = mine), and
/// optionally one more handle that becomes its handle 2.
pub fn spawnWith(cmdline: []const u8, stdin_h: ?u64, stdout_h: ?u64) ?u64 {
    return spawnFull(cmdline, stdin_h, stdout_h, null);
}

pub fn spawnFull(cmdline: []const u8, stdin_h: ?u64, stdout_h: ?u64, extra_h: ?u64) ?u64 {
    const in: u64 = if (stdin_h) |h| h + 1 else 0;
    const out: u64 = if (stdout_h) |h| h + 1 else 0;
    const extra: u64 = if (extra_h) |h| h + 1 else 0;
    return result(syscall(4, @intFromPtr(cmdline.ptr), cmdline.len, in | (out << 16) | (extra << 32)));
}

/// What a program started with spawnFull gets as its extra handle.
pub const extra_handle = 2;

pub const Pipe = struct { read: u64, write: u64 };

/// What's written to .write can be read from .read.
pub fn pipe() ?Pipe {
    const fds = result(syscall(17, 0, 0, 0)) orelse return null;
    return .{ .read = fds & 0xffff_ffff, .write = fds >> 32 };
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

pub fn mkdir(path: []const u8) bool {
    return result(syscall(10, @intFromPtr(path.ptr), path.len, 0)) != null;
}

/// Removes a file or an empty directory.
pub fn remove(path: []const u8) bool {
    return result(syscall(11, @intFromPtr(path.ptr), path.len, 0)) != null;
}

pub fn chdir(path: []const u8) bool {
    return result(syscall(12, @intFromPtr(path.ptr), path.len, 0)) != null;
}

pub fn getcwd(buf: []u8) []const u8 {
    const n = syscall(13, @intFromPtr(buf.ptr), buf.len, 0);
    return buf[0..@min(n, buf.len)];
}

/// Saves /data to the disk, returns how many files.
pub fn sync() ?u64 {
    return result(syscall(14, 0, 0, 0));
}

pub fn sleep(ms: u64) void {
    _ = syscall(15, ms, 0, 0);
}

/// Milliseconds since boot (in steps of 10).
pub fn uptime() u64 {
    return syscall(16, 0, 0, 0);
}

/// A second handle to the same thing, with at most `rights` (never more than
/// the original has). Needs the duplicate right.
pub fn duplicate(handle: u64, rights: Rights) ?u64 {
    return result(syscall(18, handle, @as(u8, @bitCast(rights)), 0));
}

/// Takes rights away from a handle, keeping only `rights`.
pub fn reduce(handle: u64, rights: Rights) void {
    _ = syscall(19, handle, @as(u8, @bitCast(rights)), 0);
}

pub const Channel = struct { a: u64, b: u64 };

/// Two connected endpoints: what's sent into one comes out of the other.
pub fn channel() ?Channel {
    const hs = result(syscall(20, 0, 0, 0)) orelse return null;
    return .{ .a = hs & 0xffff_ffff, .b = hs >> 32 };
}

pub const ChannelError = error{ PeerClosed, Failed };

/// Sends bytes (up to 64 KiB) and handles (up to 16, they move to the
/// receiver: they're gone from this program afterwards).
pub fn send(endpoint: u64, bytes: []const u8, handles: []const u64) ChannelError!void {
    const call_args = [4]u64{ @intFromPtr(bytes.ptr), bytes.len, @intFromPtr(handles.ptr), handles.len };
    const r = syscall(21, endpoint, @intFromPtr(&call_args), 0);
    if (r == peer_closed) return error.PeerClosed;
    if (r == failed) return error.Failed;
}

pub const Received = struct { bytes: []u8, handles: []u64 };

/// Waits for a message. PeerClosed once the other end is gone and nothing
/// is left.
pub fn recv(endpoint: u64, bytes: []u8, handles: []u64) ChannelError!Received {
    var call_args = [5]u64{ @intFromPtr(bytes.ptr), bytes.len, @intFromPtr(handles.ptr), handles.len, 0 };
    const r = syscall(22, endpoint, @intFromPtr(&call_args), 0);
    if (r == peer_closed) return error.PeerClosed;
    if (r == failed) return error.Failed;
    return .{ .bytes = bytes[0..r], .handles = handles[0..call_args[4]] };
}

/// Zeroed memory (rounded up to whole pages) that can be shared: send the
/// handle to another program and both can map the same pages.
pub fn memoryCreate(size: u64) ?u64 {
    return result(syscall(23, size, 0, 0));
}

/// Maps a memory object into this program. Writable needs the write right.
pub fn memoryMap(handle: u64, size: u64, writable: bool) ?[]u8 {
    const address = result(syscall(24, handle, @intFromBool(writable), 0)) orelse return null;
    return @as([*]u8, @ptrFromInt(address))[0..size];
}

pub fn memoryUnmap(memory: []u8) void {
    _ = syscall(25, @intFromPtr(memory.ptr), 0, 0);
}

const failed = std.math.maxInt(u64);
const peer_closed = failed - 1;

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
