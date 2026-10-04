// Read-only access to the initramfs: a cpio "newc" archive that Limine loads
// as a module (tools/mkinitramfs.zig makes it). At boot fs.zig copies every
// file from it into the in-memory filesystem.

const std = @import("std");
const limine = @import("limine.zig");

const log = std.log.scoped(.initramfs);

var archive: []const u8 = &.{};

pub fn init() void {
    archive = limine.module() orelse @panic("Limine didn't load the initramfs");
    log.info("initramfs: {d} KiB", .{archive.len / 1024});
}

pub const Entry = struct { name: []const u8, data: []const u8 };

/// Goes through the archive one file at a time. Stops at the end, or at the
/// first thing that doesn't look right.
pub const Iterator = struct {
    pos: usize = 0,

    pub fn next(it: *Iterator) ?Entry {
        if (archive.len - it.pos < 110) return null;
        const header = archive[it.pos..][0..110];
        if (!std.mem.eql(u8, header[0..6], "070701")) return null;
        const size = hex(header[54..62]) orelse return null;
        const name_size = hex(header[94..102]) orelse return null;
        if (name_size == 0) return null;
        var pos = it.pos + 110;
        if (archive.len - pos < name_size) return null;
        const name = archive[pos..][0 .. name_size - 1]; // without the 0 at the end
        pos = std.mem.alignForward(usize, pos + name_size, 4);
        if (std.mem.eql(u8, name, "TRAILER!!!")) return null;
        if (pos > archive.len or archive.len - pos < size) return null;
        const data = archive[pos..][0..size];
        it.pos = std.mem.alignForward(usize, pos + size, 4);
        return .{ .name = name, .data = data };
    }
};

fn hex(digits: *const [8]u8) ?usize {
    return std.fmt.parseInt(u32, digits, 16) catch null;
}
