import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import FeatureTimeline

@Suite("Interactive polls (M20-4, AC-M5)")
@MainActor
struct PollInteractionTests {
    private func pollItem(
        id: String = "p1",
        eventID: String = "$poll1",
        isOwn: Bool = true,
        details: PollDetails
    ) throws -> TimelineItem {
        TimelineItem(
            id: TimelineItemID(id),
            content: .event(TimelineEvent(
                eventID: try EventID(eventID),
                sender: try UserID(isOwn ? "@me:example.org" : "@alice:example.org"),
                senderName: isOwn ? "Me" : "Alice",
                timestamp: Date(timeIntervalSince1970: 100),
                isOwn: isOwn,
                kind: .poll(details)
            ))
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test("voting shows pending until server snapshot echoes confirmation, then clears; changing vote replaces previous")
    func pendingVoteLifecycleAndChange() async throws {
        let room = try RoomID("!polls:example.org")
        let pollID = try EventID("$poll1")
        let initial = PollDetails(
            question: "Lunch?",
            options: [
                PollOption(id: "a", text: "Pizza", votes: 0, selectedByMe: false),
                PollOption(id: "b", text: "Sushi", votes: 1, selectedByMe: false),
            ],
            visibility: .disclosed,
            maxSelections: 1,
            totalVoters: 1,
            ended: false
        )
        let port = FakeTimelinePort()
        port.addRoom(room, items: [try pollItem(details: initial)])
        let vm = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await vm.start()
        await waitUntil {
            if case .live(let rows, _, _, _) = vm.content { return rows.count == 1 }
            return false
        }

        guard case .live(let rows, _, _, _) = vm.content else { Issue.record("Expected live rows"); return }
        let row = rows[0]

        // Vote Pizza: pending stays set until the server echoes it (AC-M5).
        await vm.votePoll(row, optionID: "a")
        #expect(vm.pendingPollVotes[pollID] == ["a"])
        #expect(port.sentPollVotes(in: room).count == 1)
        #expect(port.sentPollVotes(in: room)[0].answers == ["a"])

        // Server echoes Pizza selectedByMe == true → pending clears.
        let confirmed = PollDetails(
            question: "Lunch?",
            options: [
                PollOption(id: "a", text: "Pizza", votes: 1, selectedByMe: true),
                PollOption(id: "b", text: "Sushi", votes: 1, selectedByMe: false),
            ],
            visibility: .disclosed, maxSelections: 1, totalVoters: 2, ended: false
        )
        try port.emit(.set(index: 0, try pollItem(details: confirmed)), in: room)
        await waitUntil { vm.pendingPollVotes[pollID] == nil }
        #expect(vm.pendingPollVotes[pollID] == nil)

        // Change vote to Sushi → sends ["b"], pending until server echoes.
        guard case .live(let updatedRows, _, _, _) = vm.content else { Issue.record("Expected live rows"); return }
        await vm.votePoll(updatedRows[0], optionID: "b")
        #expect(vm.pendingPollVotes[pollID] == ["b"])
        #expect(port.sentPollVotes(in: room).last?.answers == ["b"])

        let changed = PollDetails(
            question: "Lunch?",
            options: [
                PollOption(id: "a", text: "Pizza", votes: 0, selectedByMe: false),
                PollOption(id: "b", text: "Sushi", votes: 2, selectedByMe: true),
            ],
            visibility: .disclosed, maxSelections: 1, totalVoters: 2, ended: false
        )
        try port.emit(.set(index: 0, try pollItem(details: changed)), in: room)
        await waitUntil { vm.pendingPollVotes[pollID] == nil }
        #expect(vm.pendingPollVotes[pollID] == nil)
        await vm.stop()
    }

    @Test("vote failure clears pending state and reports honest error; ending own poll works and blocks non-owner")
    func voteFailureAndEndPoll() async throws {
        let room = try RoomID("!polls2:example.org")
        let ownID = try EventID("$own")
        let otherID = try EventID("$other")
        let openDetails = PollDetails(
            question: "Where?",
            options: [PollOption(id: "a", text: "Here", votes: 2), PollOption(id: "b", text: "There", votes: 0)],
            ended: false
        )
        let port = FakeTimelinePort()
        port.addRoom(room, items: [
            try pollItem(id: "p-own", eventID: "$own", isOwn: true, details: openDetails),
            try pollItem(id: "p-other", eventID: "$other", isOwn: false, details: openDetails),
        ])
        let vm = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))
        await vm.start()
        await waitUntil {
            if case .live(let rows, _, _, _) = vm.content { return rows.count == 2 }
            return false
        }
        guard case .live(let rows, _, _, _) = vm.content else { Issue.record("Expected live rows"); return }

        // Vote network failure rolls back pending and sets inline error.
        port.failNextPollAction(in: room, with: .network(retryable: true))
        await vm.votePoll(rows[0], optionID: "a")
        #expect(vm.pendingPollVotes[ownID] == nil)
        #expect(vm.pollErrors[ownID] == "Can't reach the server. Your vote wasn't sent.")

        // Non-owner cannot end someone else's poll.
        await vm.endPoll(rows[1])
        #expect(!vm.endingPolls.contains(otherID))
        #expect(port.endedPolls(in: room).isEmpty)

        // Owner ends own poll → pending until server confirms ended == true.
        await vm.endPoll(rows[0])
        #expect(vm.endingPolls.contains(ownID))
        #expect(port.endedPolls(in: room).count == 1)
        #expect(port.endedPolls(in: room)[0].fallbackText == "Poll ended. Top result: Here (2 votes).")

        let endedDetails = PollDetails(question: "Where?", options: openDetails.options, ended: true)
        try port.emit(.set(index: 0, try pollItem(id: "p-own", eventID: "$own", isOwn: true, details: endedDetails)), in: room)
        await waitUntil { !vm.endingPolls.contains(ownID) }
        #expect(!vm.endingPolls.contains(ownID))
        await vm.stop()
    }

    #if canImport(UIKit)
    @Test("PollCardView lays out disclosed, pending, undisclosed, and ended states cleanly in Light, Dark, and AX5")
    func pollCardLayoutLightDarkAX5() async throws {
        let room = try RoomID("!pui:example.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let vm = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))

        let disclosed = PollDetails(
            question: "Where should we meet for dinner?",
            options: [
                PollOption(id: "a", text: "Pizza place", votes: 3, selectedByMe: true),
                PollOption(id: "b", text: "Ramen bar", votes: 1, selectedByMe: false),
            ],
            visibility: .disclosed, maxSelections: 1, totalVoters: 4, ended: false
        )
        let pendingID = try EventID("$pend")
        let pendingPoll = PollDetails(
            question: "Preferred day?",
            options: [
                PollOption(id: "tue", text: "Tuesday", votes: 1, selectedByMe: false),
                PollOption(id: "thu", text: "Thursday", votes: 0, selectedByMe: false),
            ],
            visibility: .disclosed, maxSelections: 1, totalVoters: 1, ended: false
        )
        let undisclosed = PollDetails(
            question: "Anonymous vote",
            options: [
                PollOption(id: "y", text: "Approve", votes: 2, selectedByMe: true),
                PollOption(id: "n", text: "Revise", votes: 1, selectedByMe: false),
            ],
            visibility: .undisclosed, maxSelections: 1, totalVoters: 3, ended: false
        )
        let ended = PollDetails(
            question: "Theme colour",
            options: [
                PollOption(id: "blue", text: "Ocean blue", votes: 5, selectedByMe: true),
                PollOption(id: "green", text: "Forest green", votes: 2, selectedByMe: false),
            ],
            visibility: .disclosed, maxSelections: 1, totalVoters: 7, ended: true
        )

        vm.pendingPollVotes[pendingID] = ["thu"]

        let ownRow = TimelineRow(id: "r1", style: .ownMessage, sender: "You", text: "", eventID: try EventID("$r1"), isOwn: true, poll: disclosed)
        let pendingRow = TimelineRow(id: "r2", style: .message, sender: "Alice", text: "", eventID: pendingID, isOwn: false, poll: pendingPoll)
        let secretRow = TimelineRow(id: "r3", style: .message, sender: "Alice", text: "", eventID: try EventID("$r3"), isOwn: false, poll: undisclosed)
        let endedRow = TimelineRow(id: "r4", style: .message, sender: "Alice", text: "", eventID: try EventID("$r4"), isOwn: false, poll: ended)

        let configs: [(name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]
        let outDir = ProcessInfo.processInfo.environment["HALO_POLL_SNAPSHOT_DIR"]

        for config in configs {
            let content = VStack(alignment: .leading, spacing: 14) {
                HStack { Spacer(); PollCardView(row: ownRow, poll: disclosed, model: vm, isOwn: true) }
                PollCardView(row: pendingRow, poll: pendingPoll, model: vm, isOwn: false)
                PollCardView(row: secretRow, poll: undisclosed, model: vm, isOwn: false)
                PollCardView(row: endedRow, poll: ended, model: vm, isOwn: false)
            }
            .padding(16)
            .frame(width: 390, alignment: .leading)
            .background(HaloColor.bgPrimary)
            .environment(\.dynamicTypeSize, config.size)
            .environment(\.colorScheme, config.style == .dark ? .dark : .light)

            let host = UIHostingController(rootView: content)
            host.overrideUserInterfaceStyle = config.style
            let fitted = host.sizeThatFits(in: CGSize(width: 390, height: 10_000))
            #expect(fitted.width >= 350 && fitted.height >= 400)

            if let outDir {
                let renderer = ImageRenderer(content: content.frame(width: fitted.width, height: fitted.height))
                renderer.scale = 2
                if let uiImage = renderer.uiImage, let png = uiImage.pngData() {
                    let url = URL(fileURLWithPath: outDir).appendingPathComponent("poll-card-\(config.name).png")
                    try png.write(to: url)
                }
            }
        }
    }
    #endif
}
