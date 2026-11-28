import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Synchronization
import Testing
@testable import FeatureTimeline

@MainActor
@Suite("RoomSearchViewModel & RoomSearchBar (ROADMAP M20-11)")
struct RoomSearchViewModelTests {
    private let roomA = try! RoomID("!roomA:x.org")
    private let roomB = try! RoomID("!roomB:x.org")
    private let alice = try! UserID("@alice:x.org")

    private func makeHit(room: RoomID, id: String, body: String, ts: TimeInterval, threadRoot: EventID? = nil) throws -> MessageSearchHit {
        MessageSearchHit(
            roomID: room,
            eventID: try EventID(id),
            threadRoot: threadRoot,
            senderID: alice.rawValue,
            senderName: "Alice",
            body: body,
            timestamp: Date(timeIntervalSince1970: ts)
        )
    }

    private func makeEventItem(id: String, body: String, ts: TimeInterval) throws -> TimelineItem {
        TimelineItem(
            id: TimelineItemID("item-\(id)"),
            content: .event(TimelineEvent(
                eventID: try EventID(id),
                sender: alice,
                senderName: "Alice",
                timestamp: Date(timeIntervalSince1970: ts),
                isOwn: false,
                kind: .text(body, isEdited: false)
            ))
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test("uses SearchPort room filter, steps previous/next across pages, and jumps via M20-1 focused timeline without touching read state")
    func roomFilterSteppingAndFocusedJump() async throws {
        // Older message $old is NOT in the live timeline (only in focusable history, testing M20-1 focused jump!).
        let oldEvent = try makeEventItem(id: "$old", body: "launch plan archived", ts: 100)
        let midEvent = try makeEventItem(id: "$mid", body: "launch plan v2", ts: 200)
        let newEvent = try makeEventItem(id: "$new", body: "launch plan final", ts: 300)

        let timelinePort = FakeTimelinePort()
        timelinePort.addRoom(roomA, items: [midEvent, newEvent])
        timelinePort.addFocus(try EventID("$old"), in: roomA, items: [oldEvent, midEvent])

        let timeline = TimelineViewModel(
            coordinator: TimelineCoordinator(port: timelinePort, room: roomA),
            room: roomA,
            locale: Locale(identifier: "en_US"),
            timeZone: .gmt
        )
        await timeline.start()
        await waitUntil {
            if case .live(let rows, _, _, _) = timeline.content { return rows.count == 2 }
            return false
        }

        // Corpus has 3 hits in roomA and 1 distracting hit in roomB; pageSize = 2 forces loadMore on stepPrevious().
        let searchPort = FakeSearchPort(
            corpus: [
                try makeHit(room: roomA, id: "$new", body: "launch plan final", ts: 300),
                try makeHit(room: roomA, id: "$mid", body: "launch plan v2", ts: 200),
                try makeHit(room: roomA, id: "$old", body: "launch plan archived", ts: 100),
                try makeHit(room: roomB, id: "$other", body: "launch plan in another room", ts: 400),
            ],
            pageSize: 2
        )
        let coordinator = SearchCoordinator(port: searchPort, sleep: { _ in })
        let roomSearch = RoomSearchViewModel(
            room: roomA,
            coordinator: coordinator,
            jumpToEvent: { await timeline.jump(toEvent: $0) }
        )

        roomSearch.open()
        roomSearch.query = "launch"
        await waitUntil { roomSearch.positionText == "1 of 2+" && !roomSearch.isJumping }

        // Verified: SearchPort received room filter == roomA, and roomB's hit was excluded.
        #expect(searchPort.queries.allSatisfy { $0.room == roomA })
        #expect(roomSearch.highlightedEventID == (try EventID("$new")))
        #expect(timeline.highlightedRowID == "item-$new")
        #expect(!timeline.isFocused, "newest match is already in live rows")

        // Step previous (↑ older) → $mid (still in live rows).
        roomSearch.stepPrevious()
        await waitUntil { roomSearch.positionText == "2 of 2+" && !roomSearch.isJumping }
        #expect(roomSearch.highlightedEventID == (try EventID("$mid")))
        #expect(timeline.highlightedRowID == "item-$mid")

        // Step previous past page 1 → loads page 2 → jumps via M20-1 focused timeline to $old!
        roomSearch.stepPrevious()
        await waitUntil { roomSearch.positionText == "3 of 3" && timeline.isFocused && !roomSearch.isJumping }
        #expect(roomSearch.highlightedEventID == (try EventID("$old")))
        #expect(timeline.isFocused, "M20-1 focused timeline opened around unloaded match $old")
        #expect(timeline.highlightedRowID == "item-$old")
        #expect(!roomSearch.canStepPrevious && roomSearch.canStepNext)

        // Step next (↓ newer) → $mid.
        roomSearch.stepNext()
        await waitUntil { roomSearch.positionText == "2 of 3" && !roomSearch.isJumping }
        #expect(roomSearch.highlightedEventID == (try EventID("$mid")))

        // Closing search clears query and active highlight, leaving focused timeline intact for reading.
        roomSearch.close()
        #expect(!roomSearch.isPresented)
        #expect(roomSearch.query.isEmpty)
        #expect(roomSearch.highlightedEventID == nil)
        await timeline.stop()
    }

    @Test("shows empty state, indexing notice, error retry, and thread match handoff")
    func emptyIndexingErrorAndThreadMatch() async throws {
        let rootID = try EventID("$root")
        let replyID = try EventID("$reply")
        let searchPort = FakeSearchPort(corpus: [
            try makeHit(room: roomA, id: "$reply", body: "threaded clue", ts: 500, threadRoot: rootID),
        ])
        let coordinator = SearchCoordinator(port: searchPort, sleep: { _ in })
        let (statusStream, statusCont) = AsyncStream<SearchIndexStatus>.makeStream()
        let currentCoverage = Mutex<RoomSearchCoverage?>(RoomSearchCoverage(
            room: roomA,
            state: .partial,
            anchor: nil,
            oldest: Date(timeIntervalSince1970: 1_763_000_000)
        ))
        var jumpedEvents: [EventID] = []

        let vm = RoomSearchViewModel(
            room: roomA,
            coordinator: coordinator,
            statuses: { statusStream },
            roomCoverage: { currentCoverage.withLock { $0 } },
            jumpToEvent: { event in
                jumpedEvents.append(event)
                return true
            },
            locale: Locale(identifier: "en_US")
        )

        vm.open()
        statusCont.yield(SearchIndexStatus(phase: .indexing, completeRooms: 0, totalRooms: 2))
        await waitUntil { vm.indexNotice != nil }
        #expect(vm.indexNotice?.isIndexing == true)

        // Empty state while still indexing says "No matches so far".
        vm.query = "nonexistent"
        await waitUntil { vm.showsEmptyState }
        #expect(vm.emptyStateText == "No matches so far")

        // Once room completes indexing, notice clears and empty state becomes "No matches".
        currentCoverage.withLock { $0 = RoomSearchCoverage(room: roomA, state: .complete, anchor: nil, oldest: nil) }
        statusCont.yield(SearchIndexStatus(phase: .done, completeRooms: 2, totalRooms: 2))
        await waitUntil { vm.indexNotice == nil }
        #expect(vm.emptyStateText == "No matches")

        // Unavailable error shows honest message and retry recovers.
        searchPort.failNext(with: .storage(.unavailable))
        vm.query = "clue"
        await waitUntil { vm.errorMessage != nil }
        #expect(vm.errorMessage?.contains("not ready") == true || vm.errorMessage?.contains("isn't ready") == true)

        vm.retry()
        await waitUntil { vm.positionText == "1 of 1" && !vm.isJumping }
        #expect(vm.errorMessage == nil)
        #expect(jumpedEvents.last == rootID, "thread match jumps to its root in the room timeline")
        #expect(vm.selectedThreadMatch == RoomSearchViewModel.ThreadMatch(rootEvent: rootID, eventID: replyID))

        statusCont.finish()
        vm.close()
    }

    #if canImport(UIKit)
    @Test("RoomSearchBar renders cleanly in Light, Dark, and AX5 across results, empty, indexing, error, and thread states")
    func roomSearchBarSnapshots() async throws {
        let rootID = try EventID("$root")
        let searchPort = FakeSearchPort(corpus: [
            try makeHit(room: roomA, id: "$m1", body: "design review", ts: 300, threadRoot: rootID),
            try makeHit(room: roomA, id: "$m2", body: "design notes", ts: 200),
        ])
        let coordinator = SearchCoordinator(port: searchPort, sleep: { _ in })
        let (statusStream, statusCont) = AsyncStream<SearchIndexStatus>.makeStream()
        let vm = RoomSearchViewModel(
            room: roomA,
            coordinator: coordinator,
            statuses: { statusStream },
            roomCoverage: { RoomSearchCoverage(room: roomA, state: .partial, anchor: nil, oldest: Date(timeIntervalSince1970: 1_763_000_000)) },
            jumpToEvent: { _ in true },
            locale: Locale(identifier: "en_US")
        )
        vm.open()
        statusCont.yield(SearchIndexStatus(phase: .indexing, completeRooms: 1, totalRooms: 4))
        vm.query = "design"
        await waitUntil { vm.positionText == "1 of 2" && vm.indexNotice != nil }

        let outDir = ProcessInfo.processInfo.environment["HALO_ROOM_SEARCH_SNAPSHOT_DIR"]
        let variants: [(String, ColorScheme, DynamicTypeSize, CGFloat)] = [
            ("light", .light, .large, 393),
            ("dark", .dark, .large, 393),
            ("ax5", .light, .accessibility5, 393),
            ("dark-ax5", .dark, .accessibility5, 393),
        ]
        for (name, scheme, size, width) in variants {
            let view = RoomSearchBar(model: vm, onOpenThreadMessage: { _, _ in })
                .frame(width: width)
                .background(HaloColor.bgPrimary)
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            #expect(image.size.width >= width - 1)
            #expect(image.size.height > 60)
            if let outDir, let png = image.pngData() {
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("room-search-\(name).png")
                try png.write(to: url)
            }
        }

        statusCont.finish()
        vm.close()
    }
    #endif
}
