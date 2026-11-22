import Testing
@testable import FeatureTimeline

/// The "Jump to unread" pill (TIMELINE FR-4, D95).
@Suite("UnreadPill")
struct UnreadPillTests {
    @Test("landing far below the first unread message shows the pill, though the marker row was never laid out")
    func markerNeverLaidOut() {
        // A lazy list doesn't lay out a row 40 messages above where it lands, so that row never reports visibility at all.
        #expect(UnreadPill.isShown(hasMarker: true, landed: true, markerOnScreen: UnreadPill.markerOnScreenAtOpen, atBottom: true))
    }

    @Test("no pill while the marker is on screen, before landing, away from the bottom, or with nothing unread")
    func hidden() {
        #expect(!UnreadPill.isShown(hasMarker: true, landed: true, markerOnScreen: true, atBottom: true))
        #expect(!UnreadPill.isShown(hasMarker: true, landed: false, markerOnScreen: false, atBottom: true))
        #expect(!UnreadPill.isShown(hasMarker: true, landed: true, markerOnScreen: false, atBottom: false))
        #expect(!UnreadPill.isShown(hasMarker: false, landed: true, markerOnScreen: false, atBottom: true))
    }
}
