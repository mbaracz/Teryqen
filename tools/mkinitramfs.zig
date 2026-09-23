// Packs files into a cpio "newc" archive (same format Linux uses for its
// initramfs), which Limine loads next to the kernel.
//
//   mkinitramfs <out> <name in archive>=<file> ...
//
// Only plain files, no directories: the kernel just looks files up by their
// full name. Timestamps and owners are 0, so the same files give the same
// archive.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: mkinitramfs <out> <name>=<file> ...\n", .{});
        std.process.exit(1);
    }
    const cwd = std.Io.Dir.cwd();
    var archive: std.ArrayList(u8) = .empty;
    for (args[2..], 1..) |arg, ino| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.BadArgument;
        const data = try cwd.readFileAlloc(init.io, arg[eq + 1 ..], arena, .limited(64 * 1024 * 1024));
        try append(&archive, arena, arg[0..eq], 0o100444, data, ino);
    }
    try append(&archive, arena, "TRAILER!!!", 0, "", 0);
    try cwd.writeFile(init.io, .{ .sub_path = args[1], .data = archive.items });
}

fn append(archive: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, mode: u32, data: []const u8, ino: usize) !void {
    // magic, then 13 fields of 8 hex digits: ino mode uid gid nlink mtime
    // filesize devmajor devminor rdevmajor rdevminor namesize check
    try archive.print(gpa, "070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}", .{
        ino, mode, 0, 0, 1, 0, data.len, 0, 0, 0, 0, name.len + 1, 0,
    });
    try archive.appendSlice(gpa, name);
    try archive.append(gpa, 0);
    try padTo4(archive, gpa);
    try archive.appendSlice(gpa, data);
    try padTo4(archive, gpa);
}

fn padTo4(archive: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    while (archive.items.len % 4 != 0) try archive.append(gpa, 0);
}
