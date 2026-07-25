# Teryqen

My attempt at writing an operating system in Zig, mostly to learn how this stuff
actually works under the hood.

Right now there's basically nothing here yet. The idea for the start:

- x86_64 only, running in QEMU
- boot with Limine so I don't have to write a bootloader
- get "hello" printed on the serial port, then see where it goes from there

Long term I'd like it to be Unix-like and care about security from the beginning,
but first it has to boot.

## Building

You need Zig 0.16.0 (see `.zigversion`), QEMU and OVMF (UEFI firmware for
QEMU, on Ubuntu `sudo apt install qemu-system-x86 ovmf`).

```
zig build run
```

Zig downloads Limine by itself on the first build.

To debug, run `zig build debug` (QEMU waits for gdb) and in another terminal
`gdb -x tools/gdb/kernel.gdb`.

When the kernel panics it prints a backtrace with raw addresses. To see which
functions they are:

```
addr2line -f -e zig-out/bin/kernel 0xffffffff80001234
```
