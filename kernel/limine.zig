// Limine boot protocol stuff. Values are from Limine's PROTOCOL.md.
// Limine looks for the requests between the start and end markers.

const BaseRevision = extern struct {
    magic: [2]u64 = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },
    revision: u64 = 6,
};

const FramebufferRequest = extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,
    response: ?*const FramebufferResponse = null,
};

const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]const *const Framebuffer,
};

pub const Framebuffer = extern struct {
    address: *anyopaque,
    width: u64,
    height: u64,
    pitch: u64, // bytes per row
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
};

const HhdmRequest = extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,
    response: ?*const HhdmResponse = null,
};

const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

const MemmapRequest = extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,
    response: ?*const MemmapResponse = null,
};

const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]const *const MemmapEntry,
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: u64, // 0 = usable, the rest I don't touch
};

const ExecutableAddressRequest = extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64 = 0,
    response: ?*const ExecutableAddressResponse = null,
};

const ExecutableAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

export var requests_start linksection(".limine_requests_start") = [4]u64{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 };
export var base_revision linksection(".limine_requests") = BaseRevision{};
export var framebuffer_request linksection(".limine_requests") = FramebufferRequest{};
export var hhdm_request linksection(".limine_requests") = HhdmRequest{};
export var memmap_request linksection(".limine_requests") = MemmapRequest{};
export var executable_address_request linksection(".limine_requests") = ExecutableAddressRequest{};
export var requests_end linksection(".limine_requests_end") = [2]u64{ 0xadc0e0531bb10d03, 0x9572709f31764c62 };

/// Limine sets revision to 0 if it supports the revision we asked for.
pub fn supported() bool {
    const tag: *const volatile BaseRevision = &base_revision;
    return tag.revision == 0;
}

pub fn framebuffer() ?*const Framebuffer {
    const request: *const volatile FramebufferRequest = &framebuffer_request;
    const response = request.response orelse return null;
    if (response.framebuffer_count == 0) return null;
    return response.framebuffers[0];
}

/// Limine maps all physical memory at this offset (the "higher half direct
/// map"), so physical address p can be read at hhdm + p.
pub fn hhdmOffset() ?u64 {
    const request: *const volatile HhdmRequest = &hhdm_request;
    const response = request.response orelse return null;
    return response.offset;
}

pub fn memoryMap() ?[]const *const MemmapEntry {
    const request: *const volatile MemmapRequest = &memmap_request;
    const response = request.response orelse return null;
    return response.entries[0..response.entry_count];
}

/// Where in physical memory Limine loaded the kernel, and where it's mapped.
pub fn kernelAddress() ?ExecutableAddressResponse {
    const request: *const volatile ExecutableAddressRequest = &executable_address_request;
    const response = request.response orelse return null;
    return response.*;
}
