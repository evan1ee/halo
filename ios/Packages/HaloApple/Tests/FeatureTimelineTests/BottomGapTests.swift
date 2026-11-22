import Testing
@testable import FeatureTimeline

/// "At the bottom" decides whether the list follows the newest message (D95). Values are from the S10 scroll test room on an
/// iPhone Air: 1617.67 pt of content, a 96 pt bottom inset under the composer.
@Suite("BottomGap")
struct BottomGapTests {
    @Test("the newest row half behind the composer is not at the bottom")
    func behindComposer() {
        // The landing used to stop here: the visible rect passed the content's end, but not the inset under the composer.
        let value = BottomGap(contentHeight: 1617.67, bottomInset: 96, visibleMaxY: 1677.33)
        #expect(!value.isAtBottom)
        #expect(value.gap > 30)
    }

    @Test("scrolled to the end (and a few points short of it) is at the bottom")
    func atEnd() {
        #expect(BottomGap(contentHeight: 1617.67, bottomInset: 96, visibleMaxY: 1713.67).isAtBottom)
        #expect(BottomGap(contentHeight: 1617.67, bottomInset: 96, visibleMaxY: 1708).isAtBottom)
        #expect(BottomGap(contentHeight: 1617.67, bottomInset: 96, visibleMaxY: 1720).isAtBottom)  // bouncing past the end
    }

    @Test("a row that grew under the newest message (a 22 pt reaction) leaves the list short of the bottom")
    func grewBelow() {
        #expect(!BottomGap(contentHeight: 2627.33, bottomInset: 96, visibleMaxY: 2701).isAtBottom)
    }
}
