import Foundation
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Testing
@testable import FeatureRoomDetails

@MainActor
@Suite("RoomDetailsViewModel moderation (ROOM_MANAGEMENT FR-10, AC-ROOM-4, M20-12)")
struct RoomModerationViewModelTests {
    private let room = try! RoomID("!mod:x.org")

    private func makeDetails(permissions: RoomModerationPermissions) -> RoomDetails {
        RoomDetails(
            id: room,
            name: "Project Team",
            topic: "Release coordination",
            isDirect: false,
            isEncrypted: true,
            joinedMemberCount: 4,
            notificationMode: .allMessages,
            canEditDetails: true,
            canInvite: true,
            moderation: permissions
        )
    }

    @Test("remove, ban, and unban update lists and forward optional reasons; power levels gate what is offered")
    func removeBanUnbanAndGating() async throws {
        let creator = RoomMemberInfo(userID: "@creator:x.org", displayName: "Creator", role: .administrator, powerLevel: .infinite, isMe: true)
        let admin = RoomMemberInfo(userID: "@admin:x.org", displayName: "Alice Admin", role: .administrator, powerLevel: .level(100))
        let mod = RoomMemberInfo(userID: "@mod:x.org", displayName: "Milo Mod", role: .moderator, powerLevel: .level(50))
        let member = RoomMemberInfo(userID: "@bob:x.org", displayName: "Bob", role: .user, powerLevel: .level(0))

        let port = FakeRoomPort(
            details: makeDetails(permissions: RoomModerationPermissions(canKick: true, canBan: true, ownPowerLevel: .infinite)),
            members: [creator, admin, mod, member]
        )
        let vm = RoomDetailsViewModel(port: port, room: room)
        await vm.load()

        #expect(vm.moderationActions(for: creator).isEmpty, "cannot moderate self")
        #expect(vm.moderationActions(for: admin) == .init(canRemove: true, canBan: true, canUnban: false))
        #expect(vm.moderationActions(for: member) == .init(canRemove: true, canBan: true, canUnban: false))

        // Remove Bob with a reason.
        let removed = await vm.removeMember(member, reason: "Off-topic")
        #expect(removed)
        #expect(port.removedMembers.count == 1)
        #expect(port.removedMembers[0].user.rawValue == "@bob:x.org")
        #expect(port.removedMembers[0].reason == "Off-topic")
        if case .loaded(_, let remaining) = vm.content {
            #expect(!remaining.contains { $0.userID == "@bob:x.org" })
        } else {
            Issue.record("expected loaded content")
        }

        // Ban Milo Mod with a reason; moves to bannedMembers.
        let banned = await vm.banMember(mod, reason: "Spam")
        #expect(banned)
        #expect(port.bannedCalls.count == 1)
        #expect(vm.bannedMembers.map(\.userID) == ["@mod:x.org"])
        #expect(vm.bannedMembers.first?.banReason == "Spam")

        let bannedMod = try #require(vm.bannedMembers.first)
        #expect(vm.moderationActions(for: bannedMod) == .init(canRemove: false, canBan: false, canUnban: true))

        // Unban Milo Mod.
        let unbanned = await vm.unbanMember(bannedMod, reason: "Resolved")
        #expect(unbanned)
        #expect(port.unbannedCalls.count == 1)
        #expect(vm.bannedMembers.isEmpty)
        #expect(vm.actionError == nil)
    }

    @Test("AC-ROOM-4: server refusal (.forbidden) or offline (.network) leaves lists unchanged and explains why")
    func serverRefusalAndOfflineExplained() async {
        let me = RoomMemberInfo(userID: "@me:x.org", displayName: "Me", role: .moderator, powerLevel: .level(50), isMe: true)
        let target = RoomMemberInfo(userID: "@bob:x.org", displayName: "Bob", role: .user, powerLevel: .level(0))
        let banned = RoomMemberInfo(userID: "@eve:x.org", displayName: "Eve", role: .user, powerLevel: .level(0), isBanned: true, banReason: "Abuse")

        let port = FakeRoomPort(
            details: makeDetails(permissions: RoomModerationPermissions(canKick: true, canBan: true, ownPowerLevel: .level(50))),
            members: [me, target],
            banned: [banned]
        )
        let vm = RoomDetailsViewModel(port: port, room: room)
        await vm.load()

        // Live power levels changed on server → server returns .forbidden.
        port.fail(with: .forbidden)
        #expect(!(await vm.removeMember(target)))
        #expect(vm.actionError?.contains("permission") == true)
        if case .loaded(_, let current) = vm.content {
            #expect(current.contains { $0.userID == "@bob:x.org" }, "member list unchanged on server refusal")
        }

        // Offline ban attempt → explains offline and keeps state unchanged.
        port.fail(with: .network(retryable: true))
        #expect(!(await vm.banMember(target)))
        #expect(vm.actionError?.contains("offline") == true)
        #expect(vm.bannedMembers.map(\.userID) == ["@eve:x.org"])

        // Server refusal on unban keeps banned list unchanged and explains permission error.
        port.fail(with: .forbidden)
        #expect(!(await vm.unbanMember(banned)))
        #expect(vm.actionError?.contains("unban") == true)
        #expect(vm.bannedMembers.map(\.userID) == ["@eve:x.org"])
    }

    @Test("regular member is never offered remove, ban, or unban, and direct calls refuse without touching the port")
    func regularMemberGatedOut() async {
        let me = RoomMemberInfo(userID: "@me:x.org", displayName: "Me", role: .user, powerLevel: .level(0), isMe: true)
        let other = RoomMemberInfo(userID: "@other:x.org", displayName: "Other", role: .user, powerLevel: .level(0))
        let port = FakeRoomPort(
            details: makeDetails(permissions: .none),
            members: [me, other]
        )
        let vm = RoomDetailsViewModel(port: port, room: room)
        await vm.load()

        #expect(vm.moderationActions(for: other).isEmpty)
        #expect(!(await vm.removeMember(other)))
        #expect(port.removedMembers.isEmpty)
        #expect(vm.actionError?.contains("permission") == true)
    }

    #if canImport(UIKit)
    @Test("RoomDetailsView with roles, moderation controls, and Banned section renders cleanly in Light, Dark, and AX5")
    func moderationLightDarkAX5Snapshots() async throws {
        let creator = RoomMemberInfo(userID: "@creator:x.org", displayName: "Creator", role: .administrator, powerLevel: .infinite, isMe: true)
        let admin = RoomMemberInfo(userID: "@admin:x.org", displayName: "Alice Admin", role: .administrator, powerLevel: .level(100))
        let mod = RoomMemberInfo(userID: "@mod:x.org", displayName: "Milo Mod", role: .moderator, powerLevel: .level(50))
        let member = RoomMemberInfo(userID: "@bob:x.org", displayName: "Bob", role: .user, powerLevel: .level(0))
        let banned = RoomMemberInfo(userID: "@eve:x.org", displayName: "Eve", role: .user, powerLevel: .level(0), isBanned: true, banReason: "Spam links")

        let port = FakeRoomPort(
            details: makeDetails(permissions: RoomModerationPermissions(canKick: true, canBan: true, ownPowerLevel: .infinite)),
            members: [creator, admin, mod, member],
            banned: [banned]
        )
        let vm = RoomDetailsViewModel(port: port, room: room)
        await vm.load()

        let outDir = ProcessInfo.processInfo.environment["HALO_MODERATION_SNAPSHOT_DIR"]
        let variants: [(String, ColorScheme, DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]
        let members = [creator, admin, mod, member]
        let detailsView = RoomDetailsView(model: vm)
        for (name, scheme, size) in variants {
            let preview = VStack(alignment: .leading, spacing: HaloSpacing.m) {
                VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                    Text("MEMBERS")
                        .font(HaloTypography.caption.weight(.semibold))
                        .foregroundStyle(HaloColor.textSecondary)
                    VStack(spacing: 0) {
                        ForEach(members) { item in
                            detailsView.memberRow(item)
                                .padding(.horizontal, HaloSpacing.m)
                                .padding(.vertical, HaloSpacing.xs)
                            if item.id != members.last?.id { Divider().padding(.leading, HaloSpacing.m) }
                        }
                    }
                    .background(HaloColor.bgElevated, in: .rect(cornerRadius: HaloRadius.medium))
                }
                VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                    Text("BANNED")
                        .font(HaloTypography.caption.weight(.semibold))
                        .foregroundStyle(HaloColor.textSecondary)
                    VStack(spacing: 0) {
                        detailsView.bannedRow(banned)
                            .padding(.horizontal, HaloSpacing.m)
                            .padding(.vertical, HaloSpacing.xs)
                    }
                    .background(HaloColor.bgElevated, in: .rect(cornerRadius: HaloRadius.medium))
                }
            }
            .padding(HaloSpacing.m)
            .frame(width: 393, alignment: .topLeading)
            .background(HaloColor.bgPrimary)
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, size)

            let host = UIHostingController(rootView: preview)
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            let fitted = host.sizeThatFits(in: CGSize(width: 393, height: 1800))
            #expect(fitted.width > 0 && fitted.height > 0)
            if let outDir {
                let renderer = ImageRenderer(content: preview)
                renderer.scale = 2
                let image = try #require(renderer.uiImage)
                let png = try #require(image.pngData())
                try png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("moderation-\(name).png"))
            }
        }
    }
    #endif
}
