# Status

`zig build run` boots the kernel in QEMU through Limine and it prints
"hello from teryqen!" on the serial port. Then it halts.

## Todo

- [x] build.zig that produces a freestanding x86_64 kernel
- [x] boot it with Limine in QEMU
- [x] print something on serial
- [ ] figure out how to draw text on the framebuffer

## Notes / things to read up on

- higher half kernel, linker scripts
- QEMU serves the boot folder as a fake FAT disk (`fat:`), fine for now but
  at some point I need a real disk image
- how to debug the kernel with gdb + QEMU
