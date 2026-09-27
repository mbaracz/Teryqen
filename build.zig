const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Bare metal x86_64. No SSE/AVX etc. in the kernel for now,
    // otherwise I'd have to save those registers on every interrupt.
    const Feature = std.Target.x86.Feature;
    var sub: std.Target.Cpu.Feature.Set = .empty;
    for ([_]Feature{ .x87, .mmx, .sse, .sse2, .avx, .avx2 }) |f| {
        sub.addFeature(@intFromEnum(f));
    }
    var add: std.Target.Cpu.Feature.Set = .empty;
    add.addFeature(@intFromEnum(Feature.soft_float));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64 },
        .cpu_features_sub = sub,
        .cpu_features_add = add,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/main.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
            .red_zone = false, // interrupts would trash it
            .stack_protector = false, // zig doesn't allow it on freestanding
            .omit_frame_pointer = false,
            .unwind_tables = .none,
        }),
        // custom linker script only works with llvm + lld
        .use_llvm = true,
        .use_lld = true,
    });
    kernel.bundle_ubsan_rt = false;
    kernel.pie = true;
    kernel.entry = .{ .symbol_name = "_start" };
    kernel.setLinkerScript(b.path("kernel/linker.ld"));
    kernel.link_z_max_page_size = 0x1000;

    b.installArtifact(kernel);

    // User programs. Same CPU features as the kernel: it doesn't save
    // SSE registers on a thread switch either.
    const programs = [_][]const u8{ "shell", "hello" };

    // The initramfs: programs + a few files, packed into a cpio archive by a
    // little tool that runs on the build machine.
    const mkinitramfs = b.addExecutable(.{
        .name = "mkinitramfs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkinitramfs.zig"),
            .target = b.graph.host,
        }),
    });
    const pack = b.addRunArtifact(mkinitramfs);
    const initramfs = pack.addOutputFileArg("initramfs.cpio");
    for (programs) |name| {
        const program = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("programs/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .red_zone = false,
                .stack_protector = false,
                .unwind_tables = .none,
            }),
        });
        program.bundle_ubsan_rt = false;
        program.entry = .{ .symbol_name = "_start" };
        program.image_base = 0x400000;
        program.link_z_max_page_size = 0x1000; // segments start on their own pages
        b.installArtifact(program);
        pack.addPrefixedFileArg(b.fmt("bin/{s}=", .{name}), program.getEmittedBin());
    }
    pack.addPrefixedFileArg("etc/motd=", b.path("initramfs/etc/motd"));

    // Folder that looks like an EFI partition: Limine + config + kernel.
    // QEMU can serve a plain folder as a FAT disk (fat:...), so no need
    // to make a real disk image yet.
    const limine = b.dependency("limine", .{});
    const esp = b.addWriteFiles();
    _ = esp.addCopyFile(limine.path("BOOTX64.EFI"), "EFI/BOOT/BOOTX64.EFI");
    _ = esp.addCopyFile(b.path("boot/limine.conf"), "boot/limine/limine.conf");
    _ = esp.addCopyFile(kernel.getEmittedBin(), "boot/kernel");
    _ = esp.addCopyFile(initramfs, "boot/initramfs.cpio");

    const run = qemuCommand(b, esp.getDirectory());
    b.step("run", "Boot the kernel in QEMU").dependOn(&run.step);

    // Same, but QEMU waits for gdb on port 1234 before running anything.
    // Then: gdb -x tools/gdb/kernel.gdb
    const debug = qemuCommand(b, esp.getDirectory());
    debug.addArgs(&.{ "-s", "-S" });
    debug.step.dependOn(b.getInstallStep()); // gdb reads zig-out/bin/kernel
    b.step("debug", "Boot in QEMU and wait for gdb").dependOn(&debug.step);
}

fn qemuCommand(b: *std.Build, esp: std.Build.LazyPath) *std.Build.Step.Run {
    const qemu = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-machine",
        "q35",
        "-cpu",
        "max", // the default CPU has no x2APIC
        "-m",
        "512M",
        "-no-reboot",
        "-serial",
        "stdio",
        "-drive",
        "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd",
        "-drive",
    });
    qemu.addPrefixedDirectoryArg("if=virtio,readonly=on,format=raw,file=fat:", esp);
    qemu.stdio = .inherit;
    qemu.has_side_effects = true;
    return qemu;
}
