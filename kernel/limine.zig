// Limine boot protocol stuff. Values are from Limine's PROTOCOL.md.
// Limine looks for the requests between the start and end markers.

const BaseRevision = extern struct {
    magic: [2]u64 = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },
    revision: u64 = 6,
};

export var requests_start linksection(".limine_requests_start") = [4]u64{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 };
export var base_revision linksection(".limine_requests") = BaseRevision{};
export var requests_end linksection(".limine_requests_end") = [2]u64{ 0xadc0e0531bb10d03, 0x9572709f31764c62 };

/// Limine sets revision to 0 if it supports the revision we asked for.
pub fn supported() bool {
    const tag: *const volatile BaseRevision = &base_revision;
    return tag.revision == 0;
}
