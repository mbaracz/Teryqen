# Status

`zig build` makes a kernel ELF (zig-out/bin/kernel). It doesn't do anything
yet, it just halts.

## Todo

- [x] build.zig that produces a freestanding x86_64 kernel
- [ ] boot it with Limine in QEMU
- [ ] print something on serial
- [ ] figure out how to draw text on the framebuffer

## Notes / things to read up on

- Limine boot protocol
- higher half kernel, linker scripts
- how to debug the kernel with gdb + QEMU
