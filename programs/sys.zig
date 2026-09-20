// System calls for user programs. Same numbers as kernel/syscall.zig.

pub fn exit(code: u64) noreturn {
    _ = syscall(0, code, 0);
    unreachable;
}

pub fn write(text: []const u8) void {
    _ = syscall(1, @intFromPtr(text.ptr), text.len);
}

pub fn yield() void {
    _ = syscall(2, 0, 0);
}

fn syscall(number: u64, a: u64, b: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (number),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
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
    write("panic: ");
    write(msg);
    write("\n");
    exit(255);
}
