# Status

`zig build run` makes a disk image (GPT + FAT32 EFI partition, built by
tools/mkimage.zig) and boots it in QEMU through Limine. It prints
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

Keyboard + console: the PS/2 keyboard sends an interrupt for every key
(IRQ 1). The I/O APIC is found through the ACPI tables (MADT, kernel/acpi.zig)
and routes it to vector 33 (kernel/ioapic.zig); without an I/O APIC a thread
polls the keyboard instead. The text console on the screen
(kernel/console.zig) scrolls. Typed keys go to whoever calls read().

There's a shell (programs/shell.zig)! It runs /bin/<name> with the rest of
the line as arguments and waits for it to finish; `help`, `echo` (also
`echo text > file`), `cd`, `pwd` and `sync` are built in, and pipes work:
`ls /bin | wc` (kernel/pipe.zig, 4 KiB buffer), and so do `> file` and
`< file` for programs (the shell opens the file and passes it as the
program's stdout/stdin). Ctrl+C stops the running programs (not the shell;
at the prompt it drops the line), Ctrl+D ends input for a program reading
the keyboard (cat, wc). Programs: ls, cat, wc,
mkdir, rm, sleep, uptime, hello. Every program has a current directory
(inherited from whoever started it), paths can be relative and use "..".
Syscalls: exit, write, yield, read, spawn, wait, open, close, readdir, args,
mkdir, remove, chdir, getcwd, sync, sleep, uptime, pipe. fd 0/1 (stdin and
stdout) come from whoever started the program: keyboard and console, or a
pipe. A thread waiting in read() or wait() sleeps on a wait
queue (thread.WaitQueue) and gets no CPU until it's woken. sleep() puts the
thread on a list the timer interrupt checks every tick.

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

Disks: PCI is scanned for virtio disks (kernel/pci.zig), the driver uses the
legacy virtio interface (I/O ports). Finished requests come as MSI-X
interrupts (no I/O APIC needed), the waiting thread sleeps until then; only
at boot, before there are threads, it polls. Disk 0
is the boot image (read only, the kernel checks its MBR and GPT header at
boot), disk 1 is zig-out/data.img for saving files.

Saving files: whatever is in /data gets written to the data disk by `sync`
(shell command / syscall) and loaded back at boot (kernel/datadisk.zig, my
own tiny format: a directory sector + files one after another).

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
- [x] sleeping threads (wait for N ticks without spinning)
- [x] keyboard input + a text console on the screen
- [x] keyboard interrupt instead of polling (needs the I/O APIC -> ACPI tables)
- [x] virtio disk interrupts too, instead of polling (MSI-X)
- [x] user mode: run code in ring 3, syscalls
- [x] own page tables per process
- [x] load real programs (ELF files) instead of a blob of asm
- [x] initramfs to load programs from (read only, files looked up by name)
- [x] a real filesystem in memory (directories, writing files) + file syscalls
- [x] a shell
- [x] more programs (ls, cat...) once there's a filesystem
- [x] mkdir, rm, current directory (cd)
- [x] disk driver: virtio-blk, reading sectors works (kernel/virtio_blk.zig)
- [x] writing sectors
- [x] save files somewhere: second disk, my own simple format (/data + sync)
- [ ] subdirectories in /data, bigger files than... whatever fits in 16 MiB
- [x] waiting in read()/wait() without spinning (sleep until woken up)
- [x] sleep(ms) syscall (+ sleep and uptime programs)
- [x] pipes in the shell (a | b | c)
- [x] `>` for programs too (ls > file), and `<` (wc < file)
- [x] Ctrl+C to stop a program, Ctrl+D for end of input

## Notes / things to read up on

- higher half kernel, linker scripts
- bitmap allocator is slow (linear search), fine while nothing allocates much
- virtio disk: one request at a time per disk
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
