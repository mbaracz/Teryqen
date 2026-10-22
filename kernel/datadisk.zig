// Saving files: everything in /data goes to the second disk on sync, and comes
// back from it at boot.
//
// My own very simple format:
//   sector 0      "TERYQEN1", then the number of files (u32)
//   sectors 1-8   64 entries of 64 bytes: name (48 bytes, 0 padded),
//                 first sector (u64), size in bytes (u64)
//   sector 16...  the files, one after another
// sync writes the whole thing again every time, so there are never holes to
// worry about. Sector 0 is written last.

const std = @import("std");
const fs = @import("fs.zig");
const heap = @import("heap.zig");
const virtio_blk = @import("virtio_blk.zig");

const log = std.log.scoped(.datadisk);

const magic = "TERYQEN1";
const max_files = 64;
const first_data_sector = 16;

const Entry = extern struct {
    name: [48]u8,
    start: u64 align(1),
    size: u64 align(1),
};

pub fn init() void {
    _ = fs.mkdir("/data") catch {};
    const d = virtio_blk.disk(1) orelse {
        log.warn("no second disk, /data won't be saved", .{});
        return;
    };
    var super: [512]u8 = undefined;
    d.read(0, &super) catch |err| return log.err("can't read the data disk: {s}", .{@errorName(err)});
    if (!std.mem.eql(u8, super[0..8], magic)) {
        log.info("data disk is empty", .{});
        return;
    }
    const count = std.mem.readInt(u32, super[8..12], .little);
    var dir: [4096]u8 = undefined;
    d.read(1, &dir) catch |err| return log.err("can't read the data disk: {s}", .{@errorName(err)});
    var loaded: usize = 0;
    for (0..@min(count, max_files)) |i| {
        const e = std.mem.bytesToValue(Entry, dir[i * 64 ..][0..64]);
        const name = std.mem.sliceTo(&e.name, 0);
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/data/{s}", .{name}) catch continue;
        const file = fs.create(path, false) catch continue;
        file.data.resize(heap.allocator, e.size) catch continue;
        readInto(d, e.start, file.data.items) catch |err| {
            log.err("can't read {s}: {s}", .{ path, @errorName(err) });
            continue;
        };
        loaded += 1;
    }
    log.info("{d} files loaded into /data", .{loaded});
}

/// Writes every file in /data to the disk. Returns how many.
pub fn sync() !usize {
    const d = virtio_blk.disk(1) orelse return error.NoDisk;
    const data = try fs.lookup("/data");
    var dir: [4096]u8 = @splat(0);
    var count: usize = 0;
    var sector: u64 = first_data_sector;
    for (data.children.items) |file| {
        if (file.is_dir) continue; // only files, no subdirectories for now
        if (count == max_files) return error.TooManyFiles;
        try writeFrom(d, sector, file.data.items);
        var e: Entry = .{ .name = @splat(0), .start = sector, .size = file.data.items.len };
        @memcpy(e.name[0..file.getName().len], file.getName());
        @memcpy(dir[count * 64 ..][0..64], std.mem.asBytes(&e));
        sector += (file.data.items.len + 511) / 512;
        count += 1;
    }
    try d.write(1, &dir);
    var super: [512]u8 = @splat(0);
    @memcpy(super[0..8], magic);
    std.mem.writeInt(u32, super[8..12], @intCast(count), .little);
    try d.write(0, &super);
    return count;
}

fn readInto(d: *virtio_blk.Disk, start: u64, out: []u8) !void {
    var chunk: [4096]u8 = undefined;
    var done: usize = 0;
    var sector = start;
    while (done < out.len) {
        const n = @min(chunk.len, out.len - done);
        const sectors_len = (n + 511) / 512 * 512;
        try d.read(sector, chunk[0..sectors_len]);
        @memcpy(out[done..][0..n], chunk[0..n]);
        done += n;
        sector += sectors_len / 512;
    }
}

fn writeFrom(d: *virtio_blk.Disk, start: u64, bytes: []const u8) !void {
    var chunk: [4096]u8 = undefined;
    var done: usize = 0;
    var sector = start;
    while (done < bytes.len) {
        const n = @min(chunk.len, bytes.len - done);
        const sectors_len = (n + 511) / 512 * 512;
        @memset(chunk[0..sectors_len], 0);
        @memcpy(chunk[0..n], bytes[done..][0..n]);
        try d.write(sector, chunk[0..sectors_len]);
        done += n;
        sector += sectors_len / 512;
    }
}
