# Status

`zig build run` boots the kernel in QEMU through Limine. It prints
"hello from teryqen!" on the serial port and draws it on the screen with
my own little font. Then it halts.

CPU exceptions go to my own handlers now (GDT + IDT). int3 returns, anything
else prints the exception and all registers on serial and stops, instead
of QEMU silently rebooting. Page faults also show the address.

Logging goes through std.log to serial (log.info, log.err...). A panic
prints a backtrace (addresses, addr2line turns them into function names).

Physical memory: the kernel reads Limine's memory map and hands out 4 KiB
frames from a bitmap (kernel/pmm.zig). Physical memory is reached through
Limine's direct map (HHDM).

The kernel runs on its own page tables now (kernel/paging.zig): code is
read+execute, rodata read only, data read+write, and nothing is writable and
executable at the same time. Writing to kernel code page faults.

`zig build debug` + `gdb -x tools/gdb/kernel.gdb` stops at kmain, can step
through the kernel.

## Todo

- [x] build.zig that produces a freestanding x86_64 kernel
- [x] boot it with Limine in QEMU
- [x] print something on serial
- [x] figure out how to draw text on the framebuffer
- [ ] uppercase letters in the font
- [x] debugging with gdb
- [x] GDT and IDT, so exceptions don't just reboot QEMU
- [x] print registers when an exception happens (and the page fault address)
- [x] std.log on serial
- [x] stack trace on panic
- [x] memory map from Limine, physical page allocator
- [x] my own page tables
- [ ] kernel heap, so I can use std.ArrayList etc.
- [ ] timer interrupt

## Notes / things to read up on

- higher half kernel, linker scripts
- QEMU serves the boot folder as a fake FAT disk (`fat:`), fine for now but
  at some point I need a real disk image
- TSS + user segments in the GDT: needed for user mode, not yet
- bitmap allocator is slow (linear search), fine while nothing allocates much
- framebuffer is mapped like normal memory, write-combining would be faster
  (needs PAT)
- KASLR is off (boot/limine.conf) because of gdb, turn it back on later
