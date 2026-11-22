import Foundation

/// Preserves the reader's scroll position when older history pages are prepended while scrolled up.
enum PrependedAnchor {
    /// Returns the row ID to re-anchor at `.top` when older messages are prepended above the reader's position.
    /// Only fires after initial landing, when not following the bottom and not actively dragging, and only when the
    /// previous first row was pushed down into `rowIDs` (not replaced by a full reset).
    static func anchor(
        oldFirst: String?,
        newFirst: String?,
        rowIDs: [String],
        landed: Bool,
        pinnedToBottom: Bool,
        interacting: Bool
    ) -> String? {
        guard landed, !pinnedToBottom, !interacting,
              let oldFirst, let newFirst, oldFirst != newFirst else { return nil }
        guard let index = rowIDs.firstIndex(of: oldFirst), index > 0 else { return nil }
        return oldFirst
    }
}

/// Keeps a short room anchored just above the composer instead of floating at the top of the screen.
/// Uses `contentMargins(.top, ..., for: .scrollContent)` so `contentSize.height` is untouched and there is no feedback loop.
enum ShortRoomAlignment {
    /// Extra top margin needed to push short content down to the composer, or `0` when the room fills the screen or still has
    /// earlier history to load.
    static func topMargin(
        containerHeight: Double,
        topInset: Double,
        bottomInset: Double,
        contentHeight: Double,
        currentMargin: Double,
        canLoadEarlier: Bool
    ) -> Double {
        guard !canLoadEarlier, contentHeight > 0, containerHeight > 0 else { return 0 }
        let baseTopInset = max(0, topInset - currentMargin)
        let availableHeight = containerHeight - baseTopInset - bottomInset
        guard availableHeight > contentHeight else { return 0 }
        let margin = availableHeight - contentHeight
        return abs(margin - currentMargin) < 1 ? currentMargin : margin
    }
}

struct ShortRoomGeometry: Equatable {
    let containerHeight: Double
    let topInset: Double
    let bottomInset: Double
    let contentHeight: Double
    let canLoadEarlier: Bool
}
