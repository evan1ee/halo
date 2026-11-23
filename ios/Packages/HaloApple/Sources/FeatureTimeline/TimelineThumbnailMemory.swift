import Foundation
import HaloDomain

/// Thumbnails the timeline has already shown, readable without waiting, so a photo's view can paint on its first frame
/// whenever SwiftUI rebuilds it (a list row scrolled back into view, a list reset) instead of showing a placeholder and
/// loading again. Derived, rebuildable data (AGENTS §4.1); the bytes also stay in `MediaLoader` and, on disk, in the SDK's
/// encrypted media store (docs/matrix/MEDIA.md).
///
/// A photo you send is first a local echo whose source is a local-only reference; once the server has it, the same
/// message carries the real `mxc:` reference. `adopt` makes the picture already on screen the entry for the new reference,
/// so confirming a send never loads anything (docs/features/MEDIA_ATTACHMENTS.md §Sending).
@MainActor
final class TimelineThumbnailMemory {
    private var entries: [MediaRef: Data] = [:]
    /// References from least to most recently used.
    private var order: [MediaRef] = []
    private var bytes = 0
    private let byteLimit: Int

    init(byteLimit: Int = 48 * 1024 * 1024) { self.byteLimit = byteLimit }

    func data(for ref: MediaRef) -> Data? {
        guard let data = entries[ref] else { return nil }
        touch(ref)
        return data
    }

    func store(_ data: Data, for ref: MediaRef) {
        guard !data.isEmpty, data.count <= byteLimit else { return }
        if let old = entries[ref] { bytes -= old.count }
        entries[ref] = data
        bytes += data.count
        touch(ref)
        while bytes > byteLimit, let oldest = order.first {
            order.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) { bytes -= evicted.count }
        }
    }

    /// The picture of `old` also answers for `new` (the same message, confirmed by the server). Nothing happens if `old`
    /// was never loaded; the view then loads `new` the usual way.
    func adopt(_ old: MediaRef, as new: MediaRef) {
        guard old != new, entries[new] == nil, let data = entries[old] else { return }
        store(data, for: new)
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }

    /// Rows whose photo reference differs from the one last seen for the same row ID: the local echo that became a confirmed
    /// message. Returns the pairs to `adopt`; `known` is updated to the current references.
    static func changedReferences(rows: [TimelineRow], known: inout [String: MediaRef]) -> [(old: MediaRef, new: MediaRef)] {
        var changes: [(old: MediaRef, new: MediaRef)] = []
        var current: [String: MediaRef] = [:]
        for row in rows {
            guard let image = row.image?.ref else { continue }
            current[row.id] = image
            if let old = known[row.id], old != image { changes.append((old, image)) }
        }
        known = current
        return changes
    }

    private func touch(_ ref: MediaRef) {
        order.removeAll { $0 == ref }
        order.append(ref)
    }
}
