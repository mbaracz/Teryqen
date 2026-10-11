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
    const programs = [_][]const u8{ "shell", "hello", "ls", "cat", "mkdir", "rm" };

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

    // The disk image: GPT + a FAT32 EFI partition with Limine, its config,
    // the kernel and the initramfs (tools/mkimage.zig).
    const limine = b.dependency("limine", .{});
    const mkimage = b.addExecutable(.{
        .name = "mkimage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkimage.zig"),
            .target = b.graph.host,
        }),
    });
    const make_image = b.addRunArtifact(mkimage);
    const image = make_image.addOutputFileArg("teryqen.img");
    make_image.addPrefixedFileArg("EFI/BOOT/BOOTX64.EFI=", limine.path("BOOTX64.EFI"));
    make_image.addPrefixedFileArg("boot/limine/limine.conf=", b.path("boot/limine.conf"));
    make_image.addPrefixedFileArg("boot/kernel=", kernel.getEmittedBin());
    make_image.addPrefixedFileArg("boot/initramfs.cpio=", initramfs);
    b.step("image", "Make the disk image zig-out/teryqen.img").dependOn(&b.addInstallFile(image, "teryqen.img").step);

    const run = qemuCommand(b, image);
    b.step("run", "Boot the kernel in QEMU").dependOn(&run.step);

    // Same, but QEMU waits for gdb on port 1234 before running anything.
    // Then: gdb -x tools/gdb/kernel.gdb
    const debug = qemuCommand(b, image);
    debug.addArgs(&.{ "-s", "-S" });
    debug.step.dependOn(b.getInstallStep()); // gdb reads zig-out/bin/kernel
    b.step("debug", "Boot in QEMU and wait for gdb").dependOn(&debug.step);
}

fn qemuCommand(b: *std.Build, image: std.Build.LazyPath) *std.Build.Step.Run {
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
    // read only, so running it never changes the built image
    qemu.addPrefixedFileArg("if=virtio,readonly=on,format=raw,file=", image);
    qemu.stdio = .inherit;
    qemu.has_side_effects = true;
    return qemu;
}
