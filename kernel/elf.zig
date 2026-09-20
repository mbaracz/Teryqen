// Loads a static ELF executable (64-bit, x86_64, not PIE) into an address
// space. Only the program headers matter: every PT_LOAD segment gets
// fresh pages, its bytes from the file, the rest (.bss) zeroed.
//
// The file could be anything, so check it before trusting any offset in it.

const std = @import("std");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");

const page_size = pmm.page_size;
const user_end: u64 = 0x8000_0000_0000; // lower half

pub const Error = error{ NotElf, NotSupported, BadSegment };

/// Maps the program into `space` and returns its entry point.
pub fn load(space: u64, file: []const u8) Error!u64 {
    if (file.len < @sizeOf(std.elf.Elf64_Ehdr)) return error.NotElf;
    const header = std.mem.bytesToValue(std.elf.Elf64_Ehdr, file[0..@sizeOf(std.elf.Elf64_Ehdr)]);
    if (!std.mem.eql(u8, header.e_ident[0..4], "\x7fELF")) return error.NotElf;
    if (header.e_ident[std.elf.EI.CLASS] != std.elf.ELFCLASS64) return error.NotSupported;
    if (header.e_machine != .X86_64 or header.e_type != .EXEC) return error.NotSupported;
    if (header.e_phentsize != @sizeOf(std.elf.Elf64_Phdr)) return error.NotElf;
    const ph_end = std.math.add(u64, header.e_phoff, @as(u64, header.e_phnum) * @sizeOf(std.elf.Elf64_Phdr)) catch return error.NotElf;
    if (ph_end > file.len) return error.NotElf;

    for (0..header.e_phnum) |i| {
        const off = header.e_phoff + i * @sizeOf(std.elf.Elf64_Phdr);
        const ph = std.mem.bytesToValue(std.elf.Elf64_Phdr, file[off..][0..@sizeOf(std.elf.Elf64_Phdr)]);
        if (ph.p_type != std.elf.PT_LOAD or ph.p_memsz == 0) continue;
        try loadSegment(space, file, ph);
    }
    if (header.e_entry == 0 or header.e_entry >= user_end) return error.BadSegment;
    return header.e_entry;
}

fn loadSegment(space: u64, file: []const u8, ph: std.elf.Elf64_Phdr) Error!void {
    // must be in user memory, and the file part must be inside the file
    const end = std.math.add(u64, ph.p_vaddr, ph.p_memsz) catch return error.BadSegment;
    if (end > user_end or ph.p_filesz > ph.p_memsz) return error.BadSegment;
    const file_end = std.math.add(u64, ph.p_offset, ph.p_filesz) catch return error.BadSegment;
    if (file_end > file.len) return error.BadSegment;
    const writable = ph.p_flags & std.elf.PF_W != 0;
    const executable = ph.p_flags & std.elf.PF_X != 0;
    if (writable and executable) return error.BadSegment; // no W+X here either

    var flags: u64 = paging.USER;
    if (writable) flags |= paging.WRITABLE;
    if (!executable) flags |= paging.NO_EXECUTE;

    var page = std.mem.alignBackward(u64, ph.p_vaddr, page_size);
    while (page < end) : (page += page_size) {
        const frame = pmm.alloc() orelse return error.BadSegment;
        const dest = pmm.toVirt([page_size]u8, frame);
        @memset(dest, 0);
        // copy the part of the file that lands on this page
        const from = @max(page, ph.p_vaddr);
        const to = @min(page + page_size, ph.p_vaddr + ph.p_filesz);
        if (from < to) {
            const src = file[ph.p_offset + (from - ph.p_vaddr) ..][0 .. to - from];
            @memcpy(dest[from - page ..][0 .. to - from], src);
        }
        paging.mapIn(space, page, frame, flags);
    }
}
