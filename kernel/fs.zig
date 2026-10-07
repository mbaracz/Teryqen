// The filesystem: a tree of directories and files, all in memory (heap).
// At boot it gets everything from the initramfs; files can be created and
// written, but it's all gone after a reboot.
//
// Paths here are always from the root: "bin/ls", "/etc/motd" (a leading /
// is fine). The current directory and ".." are handled in process.zig, it
// turns every path into a full one first.

const std = @import("std");
const heap = @import("heap.zig");
const initramfs = @import("initramfs.zig");

const log = std.log.scoped(.fs);
const gpa = heap.allocator;

pub const max_name = 32;

pub const Node = struct {
    name: [max_name]u8 = undefined,
    name_len: usize = 0,
    is_dir: bool,
    data: std.ArrayList(u8) = .empty, // files
    children: std.ArrayList(*Node) = .empty, // directories

    pub fn getName(n: *const Node) []const u8 {
        return n.name[0..n.name_len];
    }
};

var root: Node = .{ .is_dir = true };

pub const Error = error{ NotFound, NotADirectory, IsADirectory, BadName, AlreadyExists, NotEmpty, OutOfMemory };

pub fn init() void {
    var files: usize = 0;
    var it: initramfs.Iterator = .{};
    while (it.next()) |entry| {
        const file = create(entry.name, true) catch |err| {
            log.err("initramfs: can't add {s}: {s}", .{ entry.name, @errorName(err) });
            continue;
        };
        file.data.appendSlice(gpa, entry.data) catch @panic("out of memory copying the initramfs");
        files += 1;
    }
    log.info("{d} files from the initramfs", .{files});
}

/// Finds the node at `path`.
pub fn lookup(path: []const u8) Error!*Node {
    var node = &root;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (!node.is_dir) return error.NotADirectory;
        node = child(node, part) orelse return error.NotFound;
    }
    return node;
}

/// Creates an empty file at `path` (or empties the one that's there). With
/// `make_parents` missing directories on the way are created too.
pub fn create(path: []const u8, make_parents: bool) Error!*Node {
    var dir = &root;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    var name = parts.next() orelse return error.BadName;
    while (parts.next()) |next| {
        dir = child(dir, name) orelse if (make_parents) try addChild(dir, name, true) else return error.NotFound;
        if (!dir.is_dir) return error.NotADirectory;
        name = next;
    }
    if (child(dir, name)) |existing| {
        if (existing.is_dir) return error.IsADirectory;
        existing.data.clearRetainingCapacity();
        return existing;
    }
    return addChild(dir, name, false);
}

pub fn mkdir(path: []const u8) Error!*Node {
    const parent, const name = try splitParent(path);
    if (child(parent, name) != null) return error.AlreadyExists;
    return addChild(parent, name, true);
}

/// Removes a file or an empty directory. The caller makes sure nobody has
/// the file open.
pub fn remove(path: []const u8) Error!void {
    const parent, const name = try splitParent(path);
    for (parent.children.items, 0..) |c, i| {
        if (!std.mem.eql(u8, c.getName(), name)) continue;
        if (c.is_dir and c.children.items.len != 0) return error.NotEmpty;
        _ = parent.children.orderedRemove(i);
        c.data.deinit(gpa);
        c.children.deinit(gpa);
        gpa.destroy(c);
        return;
    }
    return error.NotFound;
}

/// "a/b/c" -> (the directory a/b, "c")
fn splitParent(path: []const u8) Error!struct { *Node, []const u8 } {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    const name = if (slash) |i| trimmed[i + 1 ..] else trimmed;
    if (name.len == 0) return error.BadName; // the root itself
    const parent = try lookup(if (slash) |i| trimmed[0..i] else "");
    if (!parent.is_dir) return error.NotADirectory;
    return .{ parent, name };
}

fn child(dir: *Node, name: []const u8) ?*Node {
    for (dir.children.items) |c| {
        if (std.mem.eql(u8, c.getName(), name)) return c;
    }
    return null;
}

fn addChild(dir: *Node, name: []const u8, is_dir: bool) Error!*Node {
    if (name.len == 0 or name.len > max_name or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.BadName;
    const node = try gpa.create(Node);
    errdefer gpa.destroy(node);
    node.* = .{ .is_dir = is_dir, .name_len = name.len };
    @memcpy(node.name[0..name.len], name);
    try dir.children.append(gpa, node);
    return node;
}
