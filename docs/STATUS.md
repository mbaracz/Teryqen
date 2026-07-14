# Status

`zig build run` boots the kernel in QEMU through Limine. It prints
"hello from teryqen!" on the serial port and draws it on the screen with
my own little font. Then it halts.

`zig build debug` + `gdb -x tools/gdb/kernel.gdb` stops at kmain, can step
through the kernel.

## Todo

- [x] build.zig that produces a freestanding x86_64 kernel
- [x] boot it with Limine in QEMU
- [x] print something on serial
- [x] figure out how to draw text on the framebuffer
- [ ] uppercase letters in the font
- [x] debugging with gdb
- [ ] GDT and IDT, so exceptions don't just reboot QEMU

## Notes / things to read up on

- higher half kernel, linker scripts
- QEMU serves the boot folder as a fake FAT disk (`fat:`), fine for now but
  at some point I need a real disk image
- KASLR is off (boot/limine.conf) because of gdb, turn it back on later
