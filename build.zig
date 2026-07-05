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
}
