# Status

`zig build run` boots the kernel in QEMU through Limine. It prints
"hello from teryqen!" on the serial port and draws it on the screen with
my own little font.

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

There's a kernel heap (kernel/heap.zig) that is a std.mem.Allocator, so
std.ArrayList works in the kernel.

Timer: the local APIC (x2APIC mode) interrupts 100 times a second, measured
against the PIT at boot. Interrupts are on; the kernel sleeps with hlt and
shows the uptime on screen.

Kernel threads (kernel/thread.zig): spawn, yield, exit, round robin. The
timer switches threads every 20 ms, so a thread that never yields can't keep
the CPU. Heap and pmm turn interrupts off while they work, so a switch in the
middle can't break them.

Keyboard + console: a thread polls the PS/2 keyboard, typed characters show
up in a text console on the screen (kernel/console.zig) with a "> " prompt.
Shift, Caps Lock and backspace work, the console scrolls. Enter just logs the
line for now, there's nothing to run yet.

User mode: a small test program (in kernel/syscall.zig) runs in ring 3 and
calls the kernel with `syscall`: exit, write, yield. If a user program
crashes, only it gets killed. It's mapped into the kernel's own page tables
(lower half, USER pages), so only one program can run at a time.

`zig build debug` + `gdb -x tools/gdb/kernel.gdb` stops at kmain, can step
through the kernel.

## Todo

- [x] build.zig that produces a freestanding x86_64 kernel
- [x] boot it with Limine in QEMU
- [x] print something on serial
- [x] figure out how to draw text on the framebuffer
- [x] uppercase letters in the font (all printable ASCII now)
- [x] debugging with gdb
- [x] GDT and IDT, so exceptions don't just reboot QEMU
- [x] print registers when an exception happens (and the page fault address)
- [x] std.log on serial
- [x] stack trace on panic
- [x] memory map from Limine, physical page allocator
- [x] my own page tables
- [x] kernel heap, so I can use std.ArrayList etc.
- [x] timer interrupt
- [x] kernel threads and switching between them
- [x] preemption: switch threads from the timer interrupt
- [ ] sleeping threads (wait for N ticks without spinning)
- [x] keyboard input + a text console on the screen
- [ ] keyboard interrupt instead of polling (needs the I/O APIC -> ACPI tables)
- [x] user mode: run code in ring 3, syscalls
- [ ] own page tables per process
- [ ] load real programs (ELF files) instead of a blob of asm

## Notes / things to read up on

- higher half kernel, linker scripts
- QEMU serves the boot folder as a fake FAT disk (`fat:`), fine for now but
  at some point I need a real disk image
- bitmap allocator is slow (linear search), fine while nothing allocates much
- heap: pages cut into small pieces are never given back, and big
  allocations never reuse virtual addresses. Fine for now.
- syscall entry uses a global for the kernel stack, fine with one CPU
- the kernel can read/write user memory freely, write() only checks that the
  pointer is in the lower half
- "interrupts off" as a lock only works with one CPU, real spinlocks once
  there's SMP
- thread stacks have no guard page, an overflow silently eats the heap
- framebuffer is mapped like normal memory, write-combining would be faster
  (needs PAT)
- KASLR is off (boot/limine.conf) because of gdb, turn it back on later
