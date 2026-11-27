import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import FeatureTimeline

/// The timeline maps only what changed (ROADMAP M19-2).
@MainActor
@Suite("Incremental timeline (M19-2)")
struct IncrementalTimelineTests {
    private func model() throws -> TimelineViewModel {
        TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
            locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC") ?? .gmt)
    }

    private func message(_ number: Int, own: Bool = false, text: String? = nil, sender: String = "@a:x.org", name: String? = "Ann") -> TimelineItem {
        TimelineItem(id: TimelineItemID("item-\(number)"), content: .event(TimelineEvent(
            eventID: try? EventID("$e\(number):x.org"), sender: try? UserID(own ? "@me:x.org" : sender), senderName: name,
            timestamp: Date(timeIntervalSince1970: Double(number) * 60), isOwn: own,
            kind: .text(text ?? "message \(number)", isEdited: false))))
    }

    private func rows(_ model: TimelineViewModel) -> [TimelineRow] {
        if case .live(let rows, _, _, _) = model.content { rows } else { [] }
    }

    private func show(_ items: [TimelineItem], in model: TimelineViewModel) {
        model.apply(.live(.init(items: items, isPaginating: false, reachedStart: true, paginationError: nil)))
    }

    /// What the view model made before this change: every row mapped again.
    private func fullRebuild(_ items: [TimelineItem], in model: TimelineViewModel) -> [TimelineRow] {
        TimelineViewModel.collapsingStateRuns(TimelineViewModel.groupingRuns(items.map(model.row), items: items), items: items)
    }

    @Test("one new message among 2,000 maps one row")
    func newMessage() throws {
        let model = try model()
        var items = (1...2000).map { message($0) }
        show(items, in: model)
        #expect(model.rowsMapped == 2000, "the first snapshot maps everything")
        model.rowsMapped = 0
        items.append(message(2001))
        show(items, in: model)
        #expect(model.rowsMapped <= 2, "mapped \(model.rowsMapped) rows")
        #expect(rows(model) == fullRebuild(items, in: model))
    }

    @Test("an edit, a removal and an insert in the middle map only the rows they touch")
    func changesInTheMiddle() throws {
        let model = try model()
        var items = (1...500).map { message($0) }
        show(items, in: model)
        model.rowsMapped = 0
        items[250] = message(251, text: "edited")
        items.remove(at: 100)
        items.insert(message(9999), at: 300)
        show(items, in: model)
        #expect(model.rowsMapped <= 3, "mapped \(model.rowsMapped) rows")
        #expect(rows(model) == fullRebuild(items, in: model))
    }

    @Test("a change to what rows read besides the item (a bot allowlist, a sender's name) maps them again")
    func contextChange() throws {
        let model = try model()
        let items = (1...50).map { message($0) }
        show(items, in: model)
        model.rowsMapped = 0
        model.botSenders = ["@bot:x.org"]
        show(items, in: model)
        #expect(model.rowsMapped == 50)
        #expect(rows(model) == fullRebuild(items, in: model))
    }

    @Test("crossing midnight refreshes cached date-divider rows from Today to Yesterday")
    func midnightRolloverUpdatesDateDivider() throws {
        let day1 = Date(timeIntervalSince1970: 1_700_049_600)  // 2023-11-15 12:00:00 UTC
        let day2 = day1.addingTimeInterval(86_400)
        let currentNow = Mutex(day1)
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt,
            now: { currentNow.withLock { $0 } })
        let items: [TimelineItem] = [
            TimelineItem(id: TimelineItemID("div-1"), content: .virtual(.dateDivider(day1))),
            message(1),
        ]
        show(items, in: model)
        #expect(rows(model).first?.text == "Today")

        currentNow.withLock { $0 = day2 }
        show(items, in: model)
        #expect(rows(model).first?.text == "Yesterday")
    }

    @Test("randomised changes always give the rows a full rebuild gives")
    func randomised() throws {
        let model = try model()
        var generator = SeededGenerator(seed: 7)
        var items = (1...200).map { message($0, own: $0 % 7 == 0, sender: $0 % 3 == 0 ? "@b:x.org" : "@a:x.org") }
        var next = 1000
        show(items, in: model)
        for _ in 0..<300 {
            switch Int.random(in: 0..<4, using: &generator) {
            case 0: items.append(message(next, own: Bool.random(using: &generator))); next += 1
            case 1 where !items.isEmpty: items.remove(at: Int.random(in: 0..<items.count, using: &generator))
            case 2 where !items.isEmpty:
                let index = Int.random(in: 0..<items.count, using: &generator)
                let id = items[index].id.rawValue.replacingOccurrences(of: "item-", with: "")
                items[index] = message(Int(id) ?? 0, text: "changed \(next)")
                next += 1
            default: items.insert(message(next), at: Int.random(in: 0...items.count, using: &generator)); next += 1
            }
            show(items, in: model)
            #expect(rows(model) == fullRebuild(items, in: model))
        }
    }
}

/// A repeatable source of randomness for the randomised test.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
