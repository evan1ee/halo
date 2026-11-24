import Testing
@testable import FeatureTimeline

@Suite("PrependedAnchor")
struct PrependedAnchorTests {
    @Test("re-anchors to the previous first row when older pages prepend while scrolled up")
    func prependsWhileScrolledUp() {
        let rows = ["older-1", "older-2", "prev-first", "newer-1"]
        let anchor = PrependedAnchor.anchor(
            oldFirst: "prev-first",
            newFirst: "older-1",
            rowIDs: rows,
            landed: true,
            pinnedToBottom: false,
            interacting: false
        )
        #expect(anchor == "prev-first")
    }

    @Test("does not interfere before landing, while pinned to bottom, or during an active drag")
    func skipsWhenLandingPinnedOrDragging() {
        let rows = ["older-1", "prev-first", "newer-1"]
        #expect(PrependedAnchor.anchor(
            oldFirst: "prev-first", newFirst: "older-1", rowIDs: rows,
            landed: false, pinnedToBottom: false, interacting: false
        ) == nil)
        #expect(PrependedAnchor.anchor(
            oldFirst: "prev-first", newFirst: "older-1", rowIDs: rows,
            landed: true, pinnedToBottom: true, interacting: false
        ) == nil)
        #expect(PrependedAnchor.anchor(
            oldFirst: "prev-first", newFirst: "older-1", rowIDs: rows,
            landed: true, pinnedToBottom: false, interacting: true
        ) == nil)
    }

    @Test("returns nil on append, no-op, or full timeline reset")
    func skipsAppendAndReset() {
        #expect(PrependedAnchor.anchor(
            oldFirst: "first", newFirst: "first", rowIDs: ["first", "second", "third"],
            landed: true, pinnedToBottom: false, interacting: false
        ) == nil)
        #expect(PrependedAnchor.anchor(
            oldFirst: "gone", newFirst: "new-first", rowIDs: ["new-first", "new-second"],
            landed: true, pinnedToBottom: false, interacting: false
        ) == nil)
        #expect(PrependedAnchor.anchor(
            oldFirst: nil, newFirst: "first", rowIDs: ["first"],
            landed: true, pinnedToBottom: false, interacting: false
        ) == nil)
    }
}

@Suite("ShortRoomAlignment")
struct ShortRoomAlignmentTests {
    /// The List reports content height including the margin in effect (measured: 97 → 397 with a 300 pt margin).
    private func margin(top: Double = 122, bottom: Double = 90, room: Double, current: Double = 0, canLoadEarlier: Bool = false) -> Double {
        ShortRoomAlignment.topMargin(containerHeight: 912, topInset: top, bottomInset: bottom, contentHeight: room + current,
                                     currentMargin: current, canLoadEarlier: canLoadEarlier)
    }

    @Test("pushes a short room down so its newest row sits just above the composer")
    func alignsShortRoomToBottom() {
        #expect(margin(room: 97) == 603)
    }

    @Test("applying the margin gives the same margin again, whatever was applied before (no layout loop)")
    func fixedPoint() {
        let first = margin(room: 97)
        #expect(margin(room: 97, current: first) == first)
        #expect(margin(room: 97, current: 300) == first)
        #expect(margin(room: 97, current: 100) == first)
    }

    @Test("shrinks as rows arrive or the keyboard opens, and is zero once full, while history can load, or with no content")
    func shrinksAndClears() {
        #expect(margin(room: 147, current: 603) == 553)
        #expect(margin(bottom: 380, room: 147, current: 553) == 263)
        #expect(margin(room: 800) == 0)
        #expect(margin(room: 97, canLoadEarlier: true) == 0)
        #expect(margin(room: 0) == 0)
    }
}

@Suite("BottomFollowState")
struct BottomFollowStateTests {
    @Test("tapping jump-to-bottom while decelerating stays pinned across intermediate frames until reaching bottom")
    func jumpToBottomSurvivesOngoingScrollMovement() {
        var state = BottomFollowState(pinnedToBottom: false, jumpingToBottom: false)
        state.beginJumpToBottom()
        #expect(state.pinnedToBottom)
        #expect(state.jumpingToBottom)

        // Intermediate frames during ongoing deceleration / animation must NOT clear pinnedToBottom or jumpingToBottom.
        #expect(state.onScrollGeometryChanged(atBottom: false, scrollMoving: true) == false)
        #expect(state.pinnedToBottom)
        #expect(state.jumpingToBottom)

        // Reaching bottom completes the jump and keeps the list pinned.
        #expect(state.onScrollGeometryChanged(atBottom: true, scrollMoving: false) == false)
        #expect(state.pinnedToBottom)
        #expect(!state.jumpingToBottom)
    }

    @Test("user interaction cancels an in-flight jump-to-bottom and detaches when not at bottom")
    func userInteractionCancelsJumpToBottom() {
        var state = BottomFollowState()
        state.beginJumpToBottom()
        state.onUserInteractionStarted(atBottom: false)
        #expect(!state.jumpingToBottom)
        #expect(!state.pinnedToBottom)
    }

    @Test("idle layout drift re-anchors when pinned, while user scrolling detaches")
    func idleReanchorsAndScrollDetaches() {
        var state = BottomFollowState(pinnedToBottom: true, jumpingToBottom: false)
        #expect(state.onScrollGeometryChanged(atBottom: false, scrollMoving: false) == true)
        #expect(state.onScrollGeometryChanged(atBottom: false, scrollMoving: true) == false)
        #expect(!state.pinnedToBottom)
    }
}

