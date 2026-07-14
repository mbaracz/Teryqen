# Start `zig build debug` in one terminal, then in another:
#   gdb -x tools/gdb/kernel.gdb
set architecture i386:x86-64
set confirm off
file zig-out/bin/kernel
target remote localhost:1234
# needs to be a hardware breakpoint, the kernel isn't loaded yet when gdb connects
hbreak kmain
continue
