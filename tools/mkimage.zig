// Makes a bootable disk image: a GPT disk with one FAT32 EFI system
// partition holding the given files. No mtools/mount needed, the whole disk
// is built in memory and written out.
//
//   mkimage <out.img> <path in image>=<file> ...
//
// FAT32 details from Microsoft's "fatgen103" document, GPT from the UEFI
// spec. One sector per cluster, long file names (VFAT) when a name doesn't
// fit 8.3 (like limine.conf). All dates are 1980-01-01.

const std = @import("std");

const sector = 512;
const partition_start = 2048; // 1 MiB, the usual alignment
const partition_sectors = 64 * 1024 * 1024 / sector;
const disk_sectors = partition_start + partition_sectors + 2048; // room for the backup GPT
const reserved_sectors = 32;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: mkimage <out.img> <path>=<file> ...\n", .{});
        std.process.exit(1);
    }
    const cwd = std.Io.Dir.cwd();
    const root = try newDir(arena, "");
    for (args[2..]) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.BadArgument;
        const data = try cwd.readFileAlloc(init.io, arg[eq + 1 ..], arena, .limited(48 * 1024 * 1024));
        try addFile(arena, root, arg[0..eq], data);
    }
    const disk = try arena.alloc(u8, disk_sectors * sector);
    @memset(disk, 0);
    try writeFat32(arena, disk[partition_start * sector ..][0 .. partition_sectors * sector], root);
    writeGpt(disk);
    try cwd.writeFile(init.io, .{ .sub_path = args[1], .data = disk });
}

// --- the file tree ---

const Node = struct {
    name: []const u8,
    data: []const u8 = "", // files
    children: std.ArrayList(*Node) = .empty, // directories
    is_dir: bool,
    cluster: u32 = 0,
    short: [11]u8 = undefined,
};

fn newDir(gpa: std.mem.Allocator, name: []const u8) !*Node {
    const n = try gpa.create(Node);
    n.* = .{ .name = name, .is_dir = true };
    return n;
}

fn addFile(gpa: std.mem.Allocator, root: *Node, path: []const u8, data: []const u8) !void {
    var dir = root;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    var name = parts.next() orelse return error.BadPath;
    while (parts.next()) |next| {
        dir = for (dir.children.items) |c| {
            if (std.mem.eql(u8, c.name, name)) break c;
        } else blk: {
            const d = try newDir(gpa, name);
            try dir.children.append(gpa, d);
            break :blk d;
        };
        name = next;
    }
    const file = try gpa.create(Node);
    file.* = .{ .name = name, .data = data, .is_dir = false };
    try dir.children.append(gpa, file);
}

// --- FAT32 ---

const Fat = struct {
    volume: []u8,
    fat: []align(1) u32,
    data_start: usize, // first sector of cluster 2
    next_cluster: u32 = 2,

    fn clusterBytes(f: *Fat, cluster: u32) []u8 {
        return f.volume[(f.data_start + cluster - 2) * sector ..][0..sector];
    }

    /// Takes `count` clusters in a row and chains them in the FAT.
    fn allocChain(f: *Fat, count: usize) !u32 {
        const first = f.next_cluster;
        for (0..count) |i| {
            const c: u32 = first + @as(u32, @intCast(i));
            if (c + 1 >= f.fat.len) return error.DiskFull;
            f.fat[c] = if (i + 1 == count) 0x0fff_ffff else c + 1;
        }
        f.next_cluster += @intCast(count);
        return first;
    }

    /// Writes `bytes` over the chain starting at `first`.
    fn fill(f: *Fat, first: u32, bytes: []const u8) void {
        var off: usize = 0;
        var c = first;
        while (off < bytes.len) : (c += 1) {
            const n = @min(sector, bytes.len - off);
            @memcpy(f.clusterBytes(c)[0..n], bytes[off..][0..n]);
            off += n;
        }
    }
};

fn writeFat32(gpa: std.mem.Allocator, volume: []u8, root: *Node) !void {
    const total: u32 = partition_sectors;
    // FAT size depends on the cluster count which depends on the FAT size...
    var fat_sectors: u32 = 1;
    while (true) {
        const clusters = total - reserved_sectors - 2 * fat_sectors;
        const needed = ((clusters + 2) * 4 + sector - 1) / sector;
        if (needed <= fat_sectors) break;
        fat_sectors = needed;
    }

    // boot sector (BPB)
    const bs = volume[0..sector];
    bs[0..3].* = .{ 0xeb, 0x58, 0x90 };
    bs[3..11].* = "TERYQEN ".*;
    std.mem.writeInt(u16, bs[11..13], sector, .little);
    bs[13] = 1; // sectors per cluster
    std.mem.writeInt(u16, bs[14..16], reserved_sectors, .little);
    bs[16] = 2; // number of FATs
    bs[21] = 0xf8; // media: fixed disk
    std.mem.writeInt(u16, bs[24..26], 32, .little); // sectors per track
    std.mem.writeInt(u16, bs[26..28], 64, .little); // heads
    std.mem.writeInt(u32, bs[28..32], partition_start, .little); // hidden sectors
    std.mem.writeInt(u32, bs[32..36], total, .little);
    std.mem.writeInt(u32, bs[36..40], fat_sectors, .little);
    std.mem.writeInt(u32, bs[44..48], 2, .little); // root directory cluster
    std.mem.writeInt(u16, bs[48..50], 1, .little); // FSInfo sector
    std.mem.writeInt(u16, bs[50..52], 6, .little); // backup boot sector
    bs[64] = 0x80; // drive number
    bs[66] = 0x29; // extended boot signature
    std.mem.writeInt(u32, bs[67..71], 0x7e41_2026, .little); // volume id
    bs[71..82].* = "NO NAME    ".*; // no volume label
    bs[82..90].* = "FAT32   ".*;
    bs[510] = 0x55;
    bs[511] = 0xaa;

    const fat_bytes = volume[reserved_sectors * sector ..][0 .. fat_sectors * sector];
    var f: Fat = .{
        .volume = volume,
        .fat = std.mem.bytesAsSlice(u32, fat_bytes),
        .data_start = reserved_sectors + 2 * fat_sectors,
    };
    f.fat[0] = 0x0fff_fff8;
    f.fat[1] = 0x0fff_ffff;

    try placeDir(gpa, &f, root, 0);

    // FSInfo: how many clusters are free and where the next free one is
    const clusters = total - reserved_sectors - 2 * fat_sectors;
    const info = volume[sector..][0..sector];
    std.mem.writeInt(u32, info[0..4], 0x4161_5252, .little);
    std.mem.writeInt(u32, info[484..488], 0x6141_7272, .little);
    std.mem.writeInt(u32, info[488..492], clusters - (f.next_cluster - 2), .little);
    std.mem.writeInt(u32, info[492..496], f.next_cluster, .little);
    std.mem.writeInt(u32, info[508..512], 0xaa55_0000, .little);
    // backups of the boot sector and FSInfo at sectors 6 and 7
    @memcpy(volume[6 * sector ..][0 .. 2 * sector], volume[0 .. 2 * sector]);
    // second copy of the FAT
    @memcpy(volume[(reserved_sectors + fat_sectors) * sector ..][0 .. fat_sectors * sector], fat_bytes);
}

/// Gives the directory and everything below it clusters, writes file data
/// and the directory entries.
fn placeDir(gpa: std.mem.Allocator, f: *Fat, dir: *Node, parent_cluster: u32) !void {
    const is_root = dir.cluster == 0 and parent_cluster == 0 and dir.name.len == 0;
    // entries: "." and ".." (not in the root), then per child its long name
    // entries + the 8.3 one
    var entries: std.ArrayList(u8) = .empty;
    try makeShortNames(dir);
    var count: usize = if (is_root) 0 else 2;
    for (dir.children.items) |c| count += 1 + longNameEntries(c);
    dir.cluster = try f.allocChain(@max(1, (count * 32 + sector - 1) / sector));

    if (!is_root) {
        try appendEntry(gpa, &entries, ".          ".*, 0x10, dir.cluster, 0);
        try appendEntry(gpa, &entries, "..         ".*, 0x10, parent_cluster, 0);
    }
    for (dir.children.items) |c| {
        if (c.is_dir) {
            try placeDir(gpa, f, c, if (is_root) 0 else dir.cluster);
        } else if (c.data.len > 0) {
            c.cluster = try f.allocChain((c.data.len + sector - 1) / sector);
            f.fill(c.cluster, c.data);
        }
        try appendLongName(gpa, &entries, c);
        try appendEntry(gpa, &entries, c.short, if (c.is_dir) 0x10 else 0x20, c.cluster, @intCast(c.data.len));
    }
    f.fill(dir.cluster, entries.items);
}

fn appendEntry(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: [11]u8, attr: u8, cluster: u32, size: u32) !void {
    var e: [32]u8 = @splat(0);
    e[0..11].* = name;
    e[11] = attr;
    const date: u16 = (0 << 9) | (1 << 5) | 1; // 1980-01-01
    std.mem.writeInt(u16, e[16..18], date, .little); // created
    std.mem.writeInt(u16, e[18..20], date, .little); // accessed
    std.mem.writeInt(u16, e[20..22], @truncate(cluster >> 16), .little);
    std.mem.writeInt(u16, e[24..26], date, .little); // modified
    std.mem.writeInt(u16, e[26..28], @truncate(cluster), .little);
    std.mem.writeInt(u32, e[28..32], size, .little);
    try out.appendSlice(gpa, &e);
}

/// "KERNEL" stays "KERNEL     ", "limine.conf" becomes "LIMINE~1CON"
/// with a long name next to it.
fn makeShortNames(dir: *Node) !void {
    var tilde: u32 = 1;
    for (dir.children.items) |c| {
        c.short = @splat(' ');
        if (fitsShort(c.name)) {
            const dot = std.mem.indexOfScalar(u8, c.name, '.');
            const base = c.name[0 .. dot orelse c.name.len];
            @memcpy(c.short[0..base.len], base);
            if (dot) |d| @memcpy(c.short[8..][0 .. c.name.len - d - 1], c.name[d + 1 ..]);
            continue;
        }
        const dot = std.mem.lastIndexOfScalar(u8, c.name, '.');
        var len: usize = 0;
        for (c.name[0 .. dot orelse c.name.len]) |ch| {
            if (len == 6) break;
            if (!std.ascii.isAlphanumeric(ch)) continue;
            c.short[len] = std.ascii.toUpper(ch);
            len += 1;
        }
        if (tilde > 9) return error.TooManyLongNames;
        c.short[len] = '~';
        c.short[len + 1] = '0' + @as(u8, @intCast(tilde));
        tilde += 1;
        if (dot) |d| {
            var i: usize = 0;
            for (c.name[d + 1 ..]) |ch| {
                if (i == 3) break;
                if (!std.ascii.isAlphanumeric(ch)) continue;
                c.short[8 + i] = std.ascii.toUpper(ch);
                i += 1;
            }
        }
    }
}

fn fitsShort(name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const base = name[0 .. dot orelse name.len];
    const ext = if (dot) |d| name[d + 1 ..] else "";
    if (base.len == 0 or base.len > 8 or ext.len > 3) return false;
    for (name) |ch| {
        if (ch == '.') continue;
        if (!(std.ascii.isUpper(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    }
    return std.mem.count(u8, name, ".") <= 1;
}

fn longNameEntries(n: *const Node) usize {
    if (fitsShort(n.name)) return 0;
    return (n.name.len + 12) / 13;
}

/// VFAT long name: 13 characters (UTF-16) per entry, last part first.
fn appendLongName(gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: *const Node) !void {
    const count = longNameEntries(n);
    var sum: u8 = 0;
    for (n.short) |ch| sum = ((sum & 1) << 7) +% (sum >> 1) +% ch;
    var i = count;
    while (i > 0) : (i -= 1) {
        var e: [32]u8 = @splat(0);
        e[0] = @as(u8, @intCast(i)) | (if (i == count) @as(u8, 0x40) else 0);
        e[11] = 0x0f; // long name attribute
        e[13] = sum;
        const offsets = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
        for (offsets, 0..) |off, j| {
            const pos = (i - 1) * 13 + j;
            const ch: u16 = if (pos < n.name.len) n.name[pos] else if (pos == n.name.len) 0 else 0xffff;
            std.mem.writeInt(u16, e[off..][0..2], ch, .little);
        }
        try out.appendSlice(gpa, &e);
    }
}

// --- GPT ---

const esp_type = [16]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
// made up, but they don't have to be random, just unique enough
const disk_guid = [16]u8{ 0x7e, 0x41, 0x20, 0x26, 0x00, 0x01, 0x40, 0x00, 0x80, 0x00, 0x54, 0x45, 0x52, 0x59, 0x51, 0x4e };
const part_guid = [16]u8{ 0x7e, 0x41, 0x20, 0x26, 0x00, 0x02, 0x40, 0x00, 0x80, 0x00, 0x54, 0x45, 0x52, 0x59, 0x51, 0x4e };

fn writeGpt(disk: []u8) void {
    const last: u64 = disk_sectors - 1;

    // protective MBR: one partition of type 0xEE covering the disk
    const mbr = disk[0..sector];
    const p = mbr[446..][0..16];
    p[1..4].* = .{ 0x00, 0x02, 0x00 };
    p[4] = 0xee;
    p[5..8].* = .{ 0xff, 0xff, 0xff };
    std.mem.writeInt(u32, p[8..12], 1, .little);
    std.mem.writeInt(u32, p[12..16], @intCast(@min(last, 0xffff_ffff)), .little);
    mbr[510] = 0x55;
    mbr[511] = 0xaa;

    // partition entries (128 of 128 bytes), only the first one used
    var entries: [128 * 128]u8 = @splat(0);
    entries[0..16].* = esp_type;
    entries[16..32].* = part_guid;
    std.mem.writeInt(u64, entries[32..40], partition_start, .little);
    std.mem.writeInt(u64, entries[40..48], partition_start + partition_sectors - 1, .little);
    for ("EFI System", 0..) |ch, i| std.mem.writeInt(u16, entries[56 + 2 * i ..][0..2], ch, .little);
    const entries_crc = std.hash.Crc32.hash(&entries);

    @memcpy(disk[2 * sector ..][0..entries.len], &entries);
    @memcpy(disk[(last - 32) * sector ..][0..entries.len], &entries);
    writeGptHeader(disk[sector..][0..sector], 1, last, 2, entries_crc);
    writeGptHeader(disk[last * sector ..][0..sector], last, 1, last - 32, entries_crc);
}

fn writeGptHeader(h: *[sector]u8, this: u64, other: u64, entries_lba: u64, entries_crc: u32) void {
    h[0..8].* = "EFI PART".*;
    std.mem.writeInt(u32, h[8..12], 0x0001_0000, .little); // revision 1.0
    std.mem.writeInt(u32, h[12..16], 92, .little); // header size
    std.mem.writeInt(u64, h[24..32], this, .little);
    std.mem.writeInt(u64, h[32..40], other, .little);
    std.mem.writeInt(u64, h[40..48], 34, .little); // first usable
    std.mem.writeInt(u64, h[48..56], disk_sectors - 34, .little); // last usable
    h[56..72].* = disk_guid;
    std.mem.writeInt(u64, h[72..80], entries_lba, .little);
    std.mem.writeInt(u32, h[80..84], 128, .little);
    std.mem.writeInt(u32, h[84..88], 128, .little);
    std.mem.writeInt(u32, h[88..92], entries_crc, .little);
    std.mem.writeInt(u32, h[16..20], std.hash.Crc32.hash(h[0..92]), .little);
}
