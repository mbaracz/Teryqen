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

Keyboard + console: a thread polls the PS/2 keyboard, the text console on the
screen (kernel/console.zig) scrolls. Typed keys go to whoever calls read().

There's a shell (programs/shell.zig)! It runs /bin/<name> with the rest of
the line as arguments and waits for it to finish; `help`, `echo` (also
`echo text > file`), `cd` and `pwd` are built in. Programs: ls, cat, mkdir,
rm, hello. Every program has a current directory (inherited from whoever
started it), paths can be relative and use "..".
Syscalls: exit, write, yield, read, spawn, wait, open, close, readdir, args,
mkdir, remove, chdir, getcwd. fd 0 is the keyboard, fd 1 the console. A thread waiting in read() or wait()
sleeps on a wait queue (thread.WaitQueue) and gets no CPU until it's woken.

User mode: programs are written in Zig (programs/), built as normal ELF
files, packed into an initramfs (cpio archive, tools/mkinitramfs.zig) that
Limine loads next to the kernel.

Filesystem (kernel/fs.zig): a tree of directories and files in memory. At
boot it gets everything from the initramfs. Programs are loaded from it
(kernel/process.zig, kernel/elf.zig), and they can open, read and write
files and list directories. Nothing is saved, it's gone after a reboot. They run in ring 3 and call
the kernel with `syscall`: exit, write, yield (programs/sys.zig). If a user program
crashes, only it gets killed. Every program has its own page tables (the
kernel half is shared), so they all use the same addresses without seeing
each other.

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
- [x] own page tables per process
- [x] load real programs (ELF files) instead of a blob of asm
- [x] initramfs to load programs from (read only, files looked up by name)
- [x] a real filesystem in memory (directories, writing files) + file syscalls
- [x] a shell
- [x] more programs (ls, cat...) once there's a filesystem
- [x] mkdir, rm, current directory (cd)
- [ ] save files somewhere (a disk driver, virtio-blk?)
- [x] waiting in read()/wait() without spinning (sleep until woken up)
- [ ] sleep(ms) syscall

## Notes / things to read up on

- higher half kernel, linker scripts
- QEMU serves the boot folder as a fake FAT disk (`fat:`), fine for now but
  at some point I need a real disk image
- bitmap allocator is slow (linear search), fine while nothing allocates much
- heap: pages cut into small pieces are never given back, and big
  allocations never reuse virtual addresses. Fine for now.
- syscall entry uses a global for the kernel stack, fine with one CPU
- ELF loader: two segments on the same page make it panic ("page already
  mapped"), my programs don't do that but a bad file could
- syscalls check user pointers by walking the page tables (mapped, USER,
  writable if the kernel writes there), so a bad pointer just fails the
  syscall. Fine while a program has one thread and can't unmap anything.
- "interrupts off" as a lock only works with one CPU, real spinlocks once
  there's SMP
- thread stacks have no guard page, an overflow silently eats the heap
- framebuffer is mapped like normal memory, write-combining would be faster
  (needs PAT)
- KASLR is off (boot/limine.conf) because of gdb, turn it back on later
