#if canImport(UIKit)
import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Testing
import UIKit
@testable import FeatureTimeline

@MainActor
@Suite("Read receipts under others' messages & Message Info (TIMELINE FR-6, M20-9)")
struct MessageReceiptsAndInfoTests {
    @Test("Others' messages expose normalized readers with timestamps, excluding sender, ordered newest first")
    func othersMessagesExposeReceiptsAndTimestamps() async throws {
        let room = try RoomID("!r:example.org")
        let alice = try UserID("@alice:example.org")
        let bob = try UserID("@bob:example.org")
        let carol = try UserID("@carol:example.org")
        let dan = try UserID("@dan:example.org")
        let bobAvatar = MediaRef(token: "bob-pic")
        let tSent = Date(timeIntervalSince1970: 1_700_000_000)
        let tBob = Date(timeIntervalSince1970: 1_700_000_060)
        let tCarol = Date(timeIntervalSince1970: 1_700_000_120)

        let port = FakeTimelinePort()
        port.addRoom(room, items: [
            TimelineItem(id: TimelineItemID("b0"), content: .event(TimelineEvent(
                eventID: try EventID("$b0"), sender: bob, senderName: "Bob", timestamp: tSent.addingTimeInterval(-30),
                isOwn: false, kind: .text("hello", isEdited: false), senderAvatar: bobAvatar, eventType: "m.room.message"
            ))),
            TimelineItem(id: TimelineItemID("a1"), content: .event(TimelineEvent(
                eventID: try EventID("$a1"), sender: alice, senderName: "Alice", timestamp: tSent,
                isOwn: false, kind: .text("Check this out", isEdited: true),
                readReceipts: [
                    // Sender's own receipt must be excluded, matching Element Web.
                    ReadReceiptEntry(userID: alice, timestamp: tCarol.addingTimeInterval(30)),
                    ReadReceiptEntry(userID: bob, timestamp: tBob),
                    ReadReceiptEntry(userID: carol, timestamp: tCarol),
                    ReadReceiptEntry(userID: dan, timestamp: nil),
                ],
                eventType: "m.room.message"
            ))),
        ])

        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )
        vm.loadRoomEncrypted = { true }
        await vm.refreshLifecycle()
        await vm.start()
        for _ in 0..<200_000 where vm.lastRowID != "a1" { await Task.yield() }

        #expect(vm.isRoomEncrypted == true)
        guard case .live(let rows, _, _, _) = vm.content,
              let incoming = rows.first(where: { $0.id == "a1" }) else {
            Issue.record("expected incoming row a1")
            return
        }
        #expect(incoming.delivery == nil, "others' messages never show own delivery indicator")
        #expect(incoming.seenBy == 3)
        #expect(incoming.seenLabel == "Seen by 3")
        #expect(incoming.allReaders.map(\.id) == [carol.rawValue, bob.rawValue, dan.rawValue])
        #expect(incoming.allReaders[0].readAt == tCarol)
        #expect(incoming.allReaders[1].name == "Bob")
        #expect(incoming.allReaders[1].avatar == bobAvatar)
        #expect(incoming.allReaders[1].readAt == tBob)
        #expect(incoming.allReaders[2].readAt == nil)
        #expect(incoming.senderID == alice.rawValue)
        #expect(incoming.timestamp == tSent)
        #expect(incoming.eventType == "m.room.message")
    }

    @Test("No vertical layout jump when receipts appear, grow, or move away on own and others' messages")
    func noLayoutJumpWhenReceiptsMove() throws {
        let room = try RoomID("!r:example.org")
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )
        let alice = try UserID("@alice:example.org")
        let me = try UserID("@me:example.org")
        let readers1 = [try UserID("@r1:example.org")]
        let readers5 = try (1...5).map { try UserID("@r\($0):example.org") }

        func measureHeight(of row: TimelineRow) -> CGFloat {
            let host = UIHostingController(rootView: RowView(
                row: row, model: vm, onOpenThread: nil, onOpenPhoto: nil, onSaveAsSticker: nil
            ))
            let size = host.sizeThatFits(in: CGSize(width: 390, height: CGFloat.greatestFiniteMagnitude))
            return size.height
        }

        func makeRow(isOwn: Bool, endsRun: Bool, readers: [UserID]) throws -> TimelineRow {
            var r = vm.row(TimelineItem(id: TimelineItemID("m"), content: .event(TimelineEvent(
                eventID: try EventID("$m"),
                sender: isOwn ? me : alice,
                senderName: isOwn ? "Me" : "Alice",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                isOwn: isOwn,
                kind: .text("Meeting starts at 3pm in the main room.", isEdited: false),
                sendState: .sent,
                readBy: readers
            ))))
            r.endsRun = endsRun
            return r
        }

        // 1. Own message (tail of run): .sent -> 1 reader -> 5 readers
        let own0 = measureHeight(of: try makeRow(isOwn: true, endsRun: true, readers: []))
        let own1 = measureHeight(of: try makeRow(isOwn: true, endsRun: true, readers: readers1))
        let own5 = measureHeight(of: try makeRow(isOwn: true, endsRun: true, readers: readers5))
        #expect(abs(own0 - own1) < 0.5, "own row jumped: \(own0) -> \(own1)")
        #expect(abs(own0 - own5) < 0.5, "own row jumped: \(own0) -> \(own5)")

        // 2. Incoming end-of-run message: 0 -> 1 -> 5 readers
        let incEnd0 = measureHeight(of: try makeRow(isOwn: false, endsRun: true, readers: []))
        let incEnd1 = measureHeight(of: try makeRow(isOwn: false, endsRun: true, readers: readers1))
        let incEnd5 = measureHeight(of: try makeRow(isOwn: false, endsRun: true, readers: readers5))
        #expect(abs(incEnd0 - incEnd1) < 0.5, "incoming tail row jumped: \(incEnd0) -> \(incEnd1)")
        #expect(abs(incEnd0 - incEnd5) < 0.5, "incoming tail row jumped: \(incEnd0) -> \(incEnd5)")

        // 3. Incoming mid-run message (`endsRun == false`): 0 -> 1 -> 5 readers
        let incMid0 = measureHeight(of: try makeRow(isOwn: false, endsRun: false, readers: []))
        let incMid1 = measureHeight(of: try makeRow(isOwn: false, endsRun: false, readers: readers1))
        let incMid5 = measureHeight(of: try makeRow(isOwn: false, endsRun: false, readers: readers5))
        #expect(abs(incMid0 - incMid1) < 0.5, "incoming mid-run row jumped: \(incMid0) -> \(incMid1)")
        #expect(abs(incMid0 - incMid5) < 0.5, "incoming mid-run row jumped: \(incMid0) -> \(incMid5)")
    }

    @Test("MessageInfoView and incoming receipts render cleanly in Light, Dark, and AX5")
    func messageInfoAndReceiptsSnapshots() throws {
        let room = try RoomID("!r:example.org")
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: room),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )
        let alice = try UserID("@alice:example.org")
        let tSent = Date(timeIntervalSince1970: 1_700_000_000)
        var row = vm.row(TimelineItem(id: TimelineItemID("m1"), content: .event(TimelineEvent(
            eventID: try EventID("$event_info_sample_123456"),
            sender: alice,
            senderName: "Alice",
            timestamp: tSent,
            isOwn: false,
            kind: .text("Shipped the release build — please verify read receipts and message info.", isEdited: true),
            reactions: [
                ReactionSummary(key: "👍", count: 3, reactedByMe: true),
                ReactionSummary(key: "🎉", count: 1, reactedByMe: false),
            ],
            readReceipts: [
                ReadReceiptEntry(userID: try UserID("@bob:example.org"), timestamp: tSent.addingTimeInterval(45)),
                ReadReceiptEntry(userID: try UserID("@carol:example.org"), timestamp: tSent.addingTimeInterval(15)),
                ReadReceiptEntry(userID: try UserID("@dan:example.org"), timestamp: nil),
                ReadReceiptEntry(userID: try UserID("@erin:example.org"), timestamp: nil),
            ],
            eventType: "m.room.message"
        ))))
        row.endsRun = true

        let outDir = ProcessInfo.processInfo.environment["HALO_MESSAGE_INFO_SNAPSHOT_DIR"]
        let configs: [(name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]

        for config in configs {
            let preview = VStack(alignment: .leading, spacing: HaloSpacing.m) {
                RowView(row: row, model: vm, onOpenThread: nil, onOpenPhoto: nil, onSaveAsSticker: nil)
                    .padding(HaloSpacing.m)
                    .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
                MessageInfoContent(
                    row: row,
                    model: vm,
                    isPinned: true,
                    isRoomEncrypted: true,
                    onViewEditHistory: {},
                    onViewSource: {}
                )
            }
            .padding(HaloSpacing.m)
            .frame(width: 390)
            .background(HaloColor.bgPrimary)
            .environment(\.dynamicTypeSize, config.size)
            .environment(\.colorScheme, config.style == .dark ? .dark : .light)

            let host = UIHostingController(rootView: preview)
            host.overrideUserInterfaceStyle = config.style
            let size = host.sizeThatFits(in: CGSize(width: 390, height: 10_000))
            #expect(size.width > 0 && size.height > 0)

            if let outDir {
                let renderer = ImageRenderer(content: preview)
                renderer.scale = config.size.isAccessibilitySize ? 1 : 2
                let image = try #require(renderer.uiImage)
                let png = try #require(image.pngData())
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("message-info-\(config.name).png")
                try png.write(to: url)
            }
        }
    }
}
#endif
