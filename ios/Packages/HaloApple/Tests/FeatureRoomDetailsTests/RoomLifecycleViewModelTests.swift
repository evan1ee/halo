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
@testable import FeatureRoomDetails

@MainActor
@Suite("Room lifecycle views & view models (M20-8)")
struct RoomLifecycleViewModelTests {
    private func sampleDetails(id: RoomID, successor: RoomSuccessor? = nil) -> RoomDetails {
        RoomDetails(
            id: id, name: "Old Room", topic: "Topic", isDirect: false, isEncrypted: true,
            joinedMemberCount: 2, notificationMode: .allMessages, successor: successor
        )
    }

    @Test("RoomPreviewViewModel handles knock request, cancel knock, banned forget, and invite-only preview")
    func previewLifecycleFlows() async throws {
        let knockID = try RoomID("!knock:example.org")
        let bannedID = try RoomID("!banned:example.org")
        let inviteID = try RoomID("!priv:example.org")
        let rooms = FakeRoomPort(details: sampleDetails(id: knockID))
        let chats = FakeChatCreationPort()

        rooms.setPreview(RoomLifecyclePreview(
            roomID: knockID, address: "#knock:example.org", name: "Knock Club",
            topic: "Ask to enter", memberCount: 5, membership: nil, joinAccess: .knock
        ), for: "#knock:example.org")
        rooms.setPreview(RoomLifecyclePreview(
            roomID: bannedID, address: bannedID.rawValue, name: "Banned Room",
            membership: .banned, joinAccess: .public
        ), for: bannedID.rawValue)
        rooms.setPreview(RoomLifecyclePreview(
            roomID: inviteID, address: "#secret:example.org", name: "Secret Room",
            membership: nil, joinAccess: .inviteOnly
        ), for: "#secret:example.org")

        // Knock flow: preview → canKnock → knock() → .knocked → cancelKnock() leaves & forgets cleanly.
        let knockVM = RoomPreviewViewModel(address: "#knock:example.org", rooms: rooms, chats: chats)
        await knockVM.load()
        guard case .loaded(let knockPreview) = knockVM.phase else { Issue.record("expected loaded"); return }
        #expect(RoomLifecyclePolicy.presentation(for: knockPreview) == .canKnock)

        knockVM.knockReason = "Hi, let me in"
        await knockVM.knock()
        #expect(rooms.knockedAddresses.count == 1)
        #expect(rooms.knockedAddresses[0].reason == "Hi, let me in")
        guard case .loaded(let knockedPreview) = knockVM.phase else { Issue.record("expected knocked"); return }
        #expect(RoomLifecyclePolicy.presentation(for: knockedPreview) == .knocked(knockID))

        await knockVM.cancelKnock(knockID)
        #expect(rooms.leftRooms.contains(knockID))
        #expect(rooms.forgottenRooms.contains(knockID))
        #expect(knockVM.completedDismiss)

        // Banned flow: forget removes cleanly.
        let bannedVM = RoomPreviewViewModel(address: bannedID.rawValue, rooms: rooms, chats: chats)
        await bannedVM.load()
        guard case .loaded(let bannedPreview) = bannedVM.phase else { Issue.record("expected loaded"); return }
        #expect(RoomLifecyclePolicy.presentation(for: bannedPreview) == .banned(bannedID))
        await bannedVM.forget(bannedID)
        #expect(rooms.forgottenRooms.contains(bannedID))
        #expect(bannedVM.completedDismiss)

        // Invite-only flow: plain explanation, no join/knock action.
        let inviteVM = RoomPreviewViewModel(address: "#secret:example.org", rooms: rooms, chats: chats)
        await inviteVM.load()
        guard case .loaded(let invitePreview) = inviteVM.phase else { Issue.record("expected loaded"); return }
        #expect(RoomLifecyclePolicy.presentation(for: invitePreview) == .inviteOnly)
    }

    @Test("InactiveRoomsViewModel manages knocked, left, and banned rooms with zero stuck rows")
    func inactiveRoomsZeroStuckRows() async throws {
        let knocked = try RoomID("!k:example.org")
        let left = try RoomID("!l:example.org")
        let banned = try RoomID("!b:example.org")
        let rooms = FakeRoomPort(details: sampleDetails(id: left))
        rooms.setInactiveRooms([
            RoomSummary(id: knocked, name: "Pending Knock", isDirect: false, isEncrypted: false, membership: .knocked),
            RoomSummary(id: left, name: "Old Chat", isDirect: false, isEncrypted: true, membership: .left),
            RoomSummary(id: banned, name: "Banned Chat", isDirect: false, isEncrypted: false, membership: .banned),
        ])
        let chats = FakeChatCreationPort()
        let vm = InactiveRoomsViewModel(roomPort: rooms, chats: chats)

        await vm.load()
        #expect(vm.rooms.count == 3)

        await vm.cancelKnock(knocked)
        #expect(!vm.rooms.contains { $0.id == knocked })
        #expect(rooms.leftRooms.contains(knocked))

        await vm.forget(left)
        #expect(!vm.rooms.contains { $0.id == left })
        #expect(rooms.forgottenRooms.contains(left))

        await vm.forget(banned)
        #expect(vm.rooms.isEmpty)
        #expect(rooms.forgottenRooms.contains(banned))
    }

    @Test("RoomDetailsViewModel exposes tombstone successor and supports leaveAndForget")
    func detailsSuccessorAndLeaveAndForget() async throws {
        let oldID = try RoomID("!old:example.org")
        let newID = try RoomID("!new:example.org")
        let port = FakeRoomPort(details: sampleDetails(
            id: oldID, successor: RoomSuccessor(roomID: newID, reason: "Room upgraded")
        ))
        let vm = RoomDetailsViewModel(port: port, room: oldID)
        await vm.load()
        guard case .loaded(let details, _) = vm.content else { Issue.record("expected loaded"); return }
        #expect(details.successor == RoomSuccessor(roomID: newID, reason: "Room upgraded"))

        await vm.leaveAndForget()
        #expect(vm.hasLeft)
        #expect(port.leftRooms == [oldID])
        #expect(port.forgottenRooms == [oldID])
    }

    @Test("RoomPreviewCardContent and InactiveRoomRow lay out cleanly in Light, Dark, and AX5")
    func lifecycleViewsLightDarkAX5() throws {
        let knockID = try RoomID("!k:example.org")
        let bannedID = try RoomID("!b:example.org")
        let nextID = try RoomID("!next:example.org")
        let knockPreview = RoomLifecyclePreview(
            roomID: knockID, address: "#design:example.org", name: "Design Crit",
            topic: "Weekly design reviews", memberCount: 14, membership: nil, joinAccess: .knock
        )
        let invitePreview = RoomLifecyclePreview(
            roomID: nil, address: "#private:example.org", name: "Core Team",
            topic: nil, memberCount: nil, membership: nil, joinAccess: .inviteOnly
        )
        let bannedPreview = RoomLifecyclePreview(
            roomID: bannedID, address: bannedID.rawValue, name: "Public Lounge",
            topic: nil, memberCount: 42, membership: .banned, joinAccess: .public
        )
        let upgradedRow = RoomSummary(
            id: knockID, name: "Legacy Room", isDirect: false, isEncrypted: true, membership: .left,
            successor: RoomSuccessor(roomID: nextID, reason: "Upgraded to v11")
        )

        let configs: [(name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]
        let outDir = ProcessInfo.processInfo.environment["HALO_LIFECYCLE_SNAPSHOT_DIR"]

        for config in configs {
            let content = VStack(spacing: HaloSpacing.m) {
                RoomPreviewCardContent(
                    preview: knockPreview, knockReason: .constant(""), isActing: false, actionError: nil,
                    onOpen: { _ in }, onJoin: {}, onAccept: { _ in }, onDecline: { _ in },
                    onKnock: {}, onCancelKnock: { _ in }, onForget: { _ in }, onClose: {}
                )
                .padding(HaloSpacing.m)
                .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))

                RoomPreviewCardContent(
                    preview: invitePreview, knockReason: .constant(""), isActing: false, actionError: nil,
                    onOpen: { _ in }, onJoin: {}, onAccept: { _ in }, onDecline: { _ in },
                    onKnock: {}, onCancelKnock: { _ in }, onForget: { _ in }, onClose: {}
                )
                .padding(HaloSpacing.m)
                .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))

                RoomPreviewCardContent(
                    preview: bannedPreview, knockReason: .constant(""), isActing: false, actionError: nil,
                    onOpen: { _ in }, onJoin: {}, onAccept: { _ in }, onDecline: { _ in },
                    onKnock: {}, onCancelKnock: { _ in }, onForget: { _ in }, onClose: {}
                )
                .padding(HaloSpacing.m)
                .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))

                InactiveRoomRow(
                    room: upgradedRow, isWorking: false,
                    onOpenSuccessor: { _ in }, onRejoin: {}, onCancelKnock: {}, onForget: {}
                )
                .padding(HaloSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
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
                    let url = URL(fileURLWithPath: outDir).appendingPathComponent("lifecycle-\(config.name).png")
                    try png.write(to: url)
                }
            }
        }
    }
}
#endif
