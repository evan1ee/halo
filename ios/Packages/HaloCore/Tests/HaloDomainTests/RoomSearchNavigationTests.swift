import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("RoomSearchNavigator & RoomSearchIndexNotice (M20-11)")
struct RoomSearchNavigationTests {
    private let roomA = try! RoomID("!roomA:x.org")

    private func makeHit(_ index: Int, threadRoot: EventID? = nil) throws -> MessageSearchHit {
        MessageSearchHit(
            roomID: roomA,
            eventID: try EventID("$e\(index)"),
            threadRoot: threadRoot,
            senderID: "@alice:x.org",
            senderName: "Alice",
            body: "match \(index)",
            timestamp: Date(timeIntervalSince1970: Double(10_000 - index * 60))
        )
    }

    @Test("initial hits select newest match (1 of N); previous steps older, next steps newer")
    func stepPreviousAndNext() throws {
        var nav = RoomSearchNavigator()
        #expect(nav.positionText == nil)
        #expect(!nav.canStepPrevious && !nav.canStepNext)

        let hits = try (0..<3).map { try makeHit($0) }
        let first = nav.apply(hits: hits, hasMore: false, queryChanged: true)
        #expect(first?.eventID == hits[0].eventID)
        #expect(nav.positionText == "1 of 3")
        #expect(nav.canStepPrevious && !nav.canStepNext)

        // Previous (↑) steps older: 0 → 1 → 2.
        #expect(nav.stepPrevious() == .jump(hits[1]))
        #expect(nav.positionText == "2 of 3")
        #expect(nav.canStepPrevious && nav.canStepNext)

        #expect(nav.stepPrevious() == .jump(hits[2]))
        #expect(nav.positionText == "3 of 3")
        #expect(!nav.canStepPrevious && nav.canStepNext)
        #expect(nav.stepPrevious() == .none)

        // Next (↓) steps newer: 2 → 1 → 0.
        #expect(nav.stepNext() == hits[1])
        #expect(nav.positionText == "2 of 3")
        #expect(nav.stepNext() == hits[0])
        #expect(nav.positionText == "1 of 3")
        #expect(nav.stepNext() == nil)
    }

    @Test("stepping previous past last loaded hit with hasMore requests loadMore and advances when page arrives")
    func loadMoreOnStepPrevious() throws {
        var nav = RoomSearchNavigator()
        let page1 = try [makeHit(0), makeHit(1)]
        let page2 = try [makeHit(0), makeHit(1), makeHit(2), makeHit(3)]

        _ = nav.apply(hits: page1, hasMore: true, queryChanged: true)
        #expect(nav.positionText == "1 of 2+")
        #expect(nav.stepPrevious() == .jump(page1[1]))
        #expect(nav.positionText == "2 of 2+")
        #expect(nav.canStepPrevious, "hasMore keeps previous enabled at the end of page 1")

        #expect(nav.stepPrevious() == .loadMore)
        let landed = nav.apply(hits: page2, hasMore: false, queryChanged: false)
        #expect(landed == page2[2], "lands on the first hit of the newly loaded page")
        #expect(nav.positionText == "3 of 4")
    }

    @Test("background refresh keeps current match anchored when newer live hit prepends or older history appends")
    func anchoredAcrossRefreshes() throws {
        var nav = RoomSearchNavigator()
        let h1 = try makeHit(1), h2 = try makeHit(2), h3 = try makeHit(3)
        _ = nav.apply(hits: [h1, h2], hasMore: false, queryChanged: true)
        _ = nav.stepPrevious()  // anchored on h2 (index 1)

        // A live hit h0 prepends and history hit h3 appends.
        let h0 = try makeHit(0)
        let jump = nav.apply(hits: [h0, h1, h2, h3], hasMore: false, queryChanged: false)
        #expect(jump == nil, "reader stays on h2 without jumping")
        #expect(nav.selectedEventID == h2.eventID)
        #expect(nav.positionText == "3 of 4")

        // If h2 is deleted on server recheck, selection clamps to nearest valid hit and jumps.
        let replacement = nav.apply(hits: [h0, h1, h3], hasMore: false, queryChanged: false)
        #expect(replacement == h3)
        #expect(nav.positionText == "3 of 3")
    }

    @Test("index notice hides once room is complete or blocked, and explains partial, indexing, offline, paused and locked states")
    func indexNoticeStates() {
        let locale = Locale(identifier: "en_US")
        let nov2025 = Date(timeIntervalSince1970: 1_763_000_000)

        // Complete or blocked room: no notice even while other rooms are still indexing.
        let complete = RoomSearchCoverage(room: roomA, state: .complete, anchor: nil, oldest: nov2025)
        let blocked = RoomSearchCoverage(room: roomA, state: .blocked, anchor: nil, oldest: nov2025)
        let indexingStatus = SearchIndexStatus(phase: .indexing, completeRooms: 2, totalRooms: 10)
        #expect(RoomSearchIndexNotice.describe(coverage: complete, status: indexingStatus, locale: locale) == nil)
        #expect(RoomSearchIndexNotice.describe(coverage: blocked, status: indexingStatus, locale: locale) == nil)

        // Partial room actively indexing.
        let partial = RoomSearchCoverage(room: roomA, state: .partial, anchor: nil, oldest: nov2025)
        let partialNotice = RoomSearchIndexNotice.describe(coverage: partial, status: indexingStatus, locale: locale)
        #expect(partialNotice?.isIndexing == true)
        #expect(partialNotice?.text.contains("Searched back to") == true)

        // Unstarted room while offline.
        let offlineStatus = SearchIndexStatus(phase: .paused(.offline), completeRooms: 0, totalRooms: 3)
        let offlineNotice = RoomSearchIndexNotice.describe(coverage: nil, status: offlineStatus, locale: locale)
        #expect(offlineNotice?.isOffline == true)
        #expect(offlineNotice?.isIndexing == false)
        #expect(offlineNotice?.text.contains("Offline") == true)

        // Locked index always shows unavailable even if coverage looked complete earlier.
        let lockedNotice = RoomSearchIndexNotice.describe(
            coverage: complete,
            status: SearchIndexStatus(phase: .unavailable),
            locale: locale
        )
        #expect(lockedNotice?.text.contains("locked") == true)
    }
}
