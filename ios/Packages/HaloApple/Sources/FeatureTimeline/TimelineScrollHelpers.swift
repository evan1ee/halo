import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Preserves the reader's scroll position when older history pages are prepended while scrolled up.
enum PrependedAnchor {
    static let timelineStartText = "This is the start of the conversation."

    /// Returns the first stable row ID suitable for anchoring across back-pagination.
    /// Skips synthetic date dividers, read markers, the timeline-start banner, and collapsible settings rows
    /// because those can be deleted, recreated, or merged when earlier events on the same day prepend.
    static func firstStableID(in rows: [TimelineRow]) -> String? {
        rows.first { row in
            row.style != .divider
                && row.style != .marker
                && row.text != TimelineViewModel.settingsText
                && row.text != timelineStartText
        }?.id ?? rows.first { $0.style != .divider && $0.style != .marker }?.id
    }

    /// Returns the row ID to re-anchor at `.top` when older messages are prepended above the reader's position.
    /// Only fires after initial landing, when not following the bottom and not actively dragging, and only when the
    /// previous first stable row was pushed down into `rowIDs` (not replaced by a full reset).
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


/// Keeps a short room anchored just above the composer instead of floating at the top of the screen, with
/// `contentMargins(.top, ..., for: .scrollContent)`.
///
/// Measured on iOS 26/27 (2026-11-23): a List's scroll-geometry `contentSize` includes that margin and its `contentInsets.top`
/// does not (margin 0 → 300 → 100 gave content 97 → 397 → 197 with the top inset fixed at 122). The room's own height is
/// therefore `contentHeight - currentMargin`, which the margin doesn't change, so the result is a fixed point. The earlier
/// formula assumed the opposite, flipped between two margins on every layout pass, and froze rooms holding only a few
/// events at 100 % CPU (founder report and device hang logs).
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
        let roomHeight = contentHeight - currentMargin
        guard !canLoadEarlier, roomHeight > 0, containerHeight > 0 else { return 0 }
        let availableHeight = containerHeight - max(0, topInset) - bottomInset
        guard availableHeight > roomHeight else { return 0 }
        let margin = (availableHeight - roomHeight).rounded()
        return abs(margin - currentMargin) < 1 ? currentMargin : margin
    }

    /// Most margin changes allowed within one second; past that the margin is left alone (a layout loop guard).
    static let maximumChangesPerSecond = 8
}

struct ShortRoomGeometry: Equatable {
    let containerHeight: Double
    let topInset: Double
    let bottomInset: Double
    let contentHeight: Double
    let canLoadEarlier: Bool
}

/// Coordinates bottom-pinning and programmatic jump-to-bottom so tapping the floating down-arrow during an ongoing
/// deceleration or scroll animation isn't immediately cancelled by intermediate non-bottom geometry callbacks.
struct BottomFollowState: Equatable {
    var pinnedToBottom = true
    var jumpingToBottom = false

    mutating func beginJumpToBottom() {
        pinnedToBottom = true
        jumpingToBottom = true
    }

    mutating func cancelJumpToBottom() {
        jumpingToBottom = false
    }

    mutating func detach() {
        pinnedToBottom = false
        jumpingToBottom = false
    }

    mutating func onUserInteractionStarted(atBottom: Bool) {
        jumpingToBottom = false
        if !atBottom {
            pinnedToBottom = false
        }
    }

    /// Processes a scroll-geometry update and returns `true` when the list should re-anchor to the bottom row.
    mutating func onScrollGeometryChanged(atBottom: Bool, scrollMoving: Bool) -> Bool {
        if atBottom {
            pinnedToBottom = true
            jumpingToBottom = false
            return false
        }
        if jumpingToBottom {
            // Keep pinned while the jump-to-bottom task is converging so in-flight deceleration doesn't wipe it out.
            return false
        }
        if scrollMoving {
            pinnedToBottom = false
            return false
        }
        return pinnedToBottom
    }
}

#if canImport(SwiftUI)
/// A `ButtonStyle` that applies no touch-down highlight/dimming effect so placing a finger on an image, map, or
/// reply quote inside a `List` to begin scrolling never flashes a tap effect, while still letting `UIScrollView`
/// cancel the button cleanly on vertical drags.
struct ScrollFriendlyTapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Attaches a scroll-safe long-press gesture that never delays or blocks `UIScrollView` vertical panning and never
/// mutates view state on touch-down (preventing the tap/scale flash when scrolling over images, maps, or messages).
struct ScrollSafeLongPressModifier: ViewModifier {
    let enabled: Bool
    let onTrigger: () -> Void

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        if enabled {
            content.gesture(ScrollSafeLongPress(onTrigger: onTrigger))
        } else {
            content
        }
        #else
        if enabled {
            content.onLongPressGesture(minimumDuration: 0.4, maximumDistance: 10, perform: onTrigger)
        } else {
            content
        }
        #endif
    }
}

#if canImport(UIKit)
private struct ScrollSafeLongPress: UIGestureRecognizerRepresentable {
    let onTrigger: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.4
        recognizer.allowableMovement = 10
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began {
            onTrigger()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
#endif
