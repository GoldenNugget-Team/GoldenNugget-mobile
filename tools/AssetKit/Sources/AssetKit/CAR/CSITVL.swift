import Foundation

/// Serialises a list of TVL entries to the contiguous byte block CoreUI
/// expects between the 184-byte CSI header and the rendition body.
enum CSITVL {
    static func encode(_ entries: [TVLEntry]) -> Data {
        var w = ByteWriter()
        for entry in entries {
            entry.encode(into: &w)
        }
        return w.data
    }
}
