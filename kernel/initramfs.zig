// Read-only access to the initramfs: a cpio "newc" archive that Limine loads
// as a module (tools/mkinitramfs.zig makes it). No real filesystem yet, files
// are just looked up by name in the archive.

const std = @import("std");
const limine = @import("limine.zig");

const log = std.log.scoped(.initramfs);

var archive: []const u8 = &.{};

pub fn init() void {
    archive = limine.module() orelse @panic("Limine didn't load the initramfs");
    log.info("initramfs: {d} KiB", .{archive.len / 1024});
}

/// Contents of the file called `name`, or null if it isn't there (or the
/// archive is broken).
pub fn find(name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (true) {
        if (archive.len - pos < 110) return null;
        const header = archive[pos..][0..110];
        if (!std.mem.eql(u8, header[0..6], "070701")) return null;
        const size = hex(header[54..62]) orelse return null;
        const name_size = hex(header[94..102]) orelse return null;
        if (name_size == 0) return null;
        pos += 110;
        if (archive.len - pos < name_size) return null;
        const entry_name = archive[pos..][0 .. name_size - 1]; // without the 0 at the end
        pos = std.mem.alignForward(usize, pos + name_size, 4);
        if (std.mem.eql(u8, entry_name, "TRAILER!!!")) return null;
        if (pos > archive.len or archive.len - pos < size) return null;
        const data = archive[pos..][0..size];
        if (std.mem.eql(u8, entry_name, name)) return data;
        pos = std.mem.alignForward(usize, pos + size, 4);
    }
}

fn hex(digits: *const [8]u8) ?usize {
    return std.fmt.parseInt(u32, digits, 16) catch null;
}
