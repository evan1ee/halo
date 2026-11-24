import HaloFoundation

/// Turns "removed, then added again in the same place" into one replacement.
///
/// The SDK sends a local echo's confirmation as a `remove` followed by a `pushBack`/`insert` of an item with the *same*
/// unique ID (it recycles the ID so the UI sees one message). Applied one diff at a time, the list shows the message gone
/// for a moment, so SwiftUI destroys the row's views and builds new, empty ones: a photo turns into a grey placeholder
/// and is loaded again. Seen with a photo sent to a self-hosted server (docs/features/MEDIA_ATTACHMENTS.md §Sending).
///
/// The coalescer mirrors the list's IDs (not its content) and rewrites such a pair, when both diffs are in one batch and the
/// message keeps its position, to `.set(index:)`. A message that really moves, or is really removed, passes through
/// unchanged. Diffs that don't fit the mirror pass through too: the downstream `ListReducer` reports the disagreement.
public struct TimelineDiffCoalescer: Sendable {
    private var ids: [TimelineItemID] = []

    public init() {}

    /// The diffs to apply for one batch from the source, in order.
    public mutating func coalesce(_ batch: [TimelineDiff]) -> [TimelineDiff] {
        var output: [TimelineDiff] = []
        var pending: (index: Int, id: TimelineItemID)?
        for diff in batch {
            if let removed = pending {
                if let item = Self.readded(diff, listCount: ids.count), item.item.id == removed.id, item.index == removed.index {
                    ids.insert(removed.id, at: removed.index)
                    output.append(.set(index: removed.index, item.item))
                    pending = nil
                    continue
                }
                output.append(.remove(index: removed.index))
                pending = nil
            }
            if case .remove(let index) = diff, ids.indices.contains(index) {
                pending = (index, ids[index])
                ids.remove(at: index)
                continue
            }
            mirror(diff)
            output.append(diff)
        }
        if let removed = pending { output.append(.remove(index: removed.index)) }
        return output
    }

    /// The single item a diff adds and where it lands, or `nil` for any other diff.
    private static func readded(_ diff: TimelineDiff, listCount: Int) -> (index: Int, item: TimelineItem)? {
        switch diff {
        case .pushBack(let item): (listCount, item)
        case .pushFront(let item): (0, item)
        case .insert(let index, let item): (index, item)
        case .append(let items) where items.count == 1: items.first.map { (listCount, $0) }
        default: nil
        }
    }

    /// Keeps the ID list in step with a diff that passes through (out-of-range diffs leave it unchanged).
    private mutating func mirror(_ diff: TimelineDiff) {
        switch diff {
        case .append(let values): ids.append(contentsOf: values.map(\.id))
        case .clear: ids.removeAll()
        case .pushFront(let value): ids.insert(value.id, at: 0)
        case .pushBack(let value): ids.append(value.id)
        case .popFront: if !ids.isEmpty { ids.removeFirst() }
        case .popBack: if !ids.isEmpty { ids.removeLast() }
        case .insert(let index, let value): if (0...ids.count).contains(index) { ids.insert(value.id, at: index) }
        case .set(let index, let value): if ids.indices.contains(index) { ids[index] = value.id }
        case .remove(let index): if ids.indices.contains(index) { ids.remove(at: index) }
        case .truncate(let length): if length >= 0, length < ids.count { ids.removeLast(ids.count - length) }
        case .reset(let values): ids = values.map(\.id)
        }
    }
}
