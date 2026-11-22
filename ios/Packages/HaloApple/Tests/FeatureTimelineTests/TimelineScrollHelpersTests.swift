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
    @Test("pushes a short room down so its newest message sits just above the composer")
    func alignsShortRoomToBottom() {
        let margin = ShortRoomAlignment.topMargin(
            containerHeight: 852,
            topInset: 100,
            bottomInset: 96,
            contentHeight: 140,
            currentMargin: 0,
            canLoadEarlier: false
        )
        #expect(margin == 516)
    }

    @Test("reaches a stable fixed point once the margin is applied")
    func stableFixedPoint() {
        let next = ShortRoomAlignment.topMargin(
            containerHeight: 852,
            topInset: 616,  // 100 base + 516 applied
            bottomInset: 96,
            contentHeight: 140,
            currentMargin: 516,
            canLoadEarlier: false
        )
        #expect(next == 516)
    }

    @Test("shrinks as messages arrive or the keyboard opens, and drops to zero once full")
    func shrinksAndClears() {
        let afterMessage = ShortRoomAlignment.topMargin(
            containerHeight: 852,
            topInset: 616,
            bottomInset: 96,
            contentHeight: 190,
            currentMargin: 516,
            canLoadEarlier: false
        )
        #expect(afterMessage == 466)

        let withKeyboard = ShortRoomAlignment.topMargin(
            containerHeight: 852,
            topInset: 566,  // 100 base + 466 applied
            bottomInset: 380,
            contentHeight: 190,
            currentMargin: 466,
            canLoadEarlier: false
        )
        #expect(withKeyboard == 182)

        let fullRoom = ShortRoomAlignment.topMargin(
            containerHeight: 852,
            topInset: 100,
            bottomInset: 96,
            contentHeight: 700,
            currentMargin: 0,
            canLoadEarlier: false
        )
        #expect(fullRoom == 0)
    }

    @Test("stays zero while earlier history can still load or when empty")
    func zeroWhilePaginatingOrEmpty() {
        #expect(ShortRoomAlignment.topMargin(
            containerHeight: 852, topInset: 100, bottomInset: 96,
            contentHeight: 140, currentMargin: 0, canLoadEarlier: true
        ) == 0)
        #expect(ShortRoomAlignment.topMargin(
            containerHeight: 852, topInset: 100, bottomInset: 96,
            contentHeight: 0, currentMargin: 0, canLoadEarlier: false
        ) == 0)
    }
}
