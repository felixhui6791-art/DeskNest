import CoreGraphics
import Foundation

/// Last successful previews survive refresh failures. Identity checks prevent
/// a recycled window ID from showing another item's image. Memory-only cache.
struct MenuBarIconCache<Image> {
    struct Identity: Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let ownerName: String
        let title: String?
        let size: CGSize

        init(_ item: FoldedMenuBarItem) {
            windowID = item.windowID
            pid = item.pid
            ownerName = item.ownerName
            title = item.title
            size = item.frame.size
        }
    }

    private struct Entry {
        let identity: Identity
        let image: Image
        let capturedAt: TimeInterval
    }
    private var entries: [CGWindowID: Entry] = [:]

    func image(for identity: Identity) -> Image? {
        guard let entry = entries[identity.windowID], entry.identity == identity else { return nil }
        return entry.image
    }

    func needsRefresh(_ identity: Identity, at now: TimeInterval) -> Bool {
        guard let entry = entries[identity.windowID], entry.identity == identity else { return true }
        return now - entry.capturedAt >= 15 || now < entry.capturedAt
    }

    mutating func insert(_ image: Image, for identity: Identity, at now: TimeInterval) {
        entries[identity.windowID] = Entry(identity: identity, image: image, capturedAt: now)
        if entries.count > 256, let oldest = entries.min(by: { $0.value.capturedAt < $1.value.capturedAt }) {
            entries.removeValue(forKey: oldest.key)
        }
    }

    mutating func retainWindows(_ windows: [CGWindowID: pid_t]) {
        entries = entries.filter { windows[$0.key] == $0.value.identity.pid }
    }

    mutating func removeAll() { entries.removeAll() }
}
