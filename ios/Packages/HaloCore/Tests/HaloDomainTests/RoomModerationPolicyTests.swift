import HaloDomain
import HaloFoundation
import Testing

@Suite("RoomModerationPolicy (ROOM_MANAGEMENT FR-10, AC-ROOM-4, M20-12)")
struct RoomModerationPolicyTests {
    private func member(
        _ id: String,
        role: RoomMemberRole = .user,
        power: RoomPowerLevel = .level(0),
        invited: Bool = false,
        banned: Bool = false,
        isMe: Bool = false
    ) -> RoomMemberInfo {
        RoomMemberInfo(
            userID: id,
            displayName: id,
            role: role,
            powerLevel: power,
            isInvited: invited,
            isBanned: banned,
            isMe: isMe
        )
    }

    @Test("regular user has no moderation actions; no user can moderate themselves")
    func regularUserAndSelf() {
        let target = member("@bob:x.org")
        let me = member("@me:x.org", role: .administrator, power: .level(100), isMe: true)
        #expect(RoomModerationPolicy.actions(for: target, permissions: .none).isEmpty)
        let adminPerms = RoomModerationPermissions(canKick: true, canBan: true, ownPowerLevel: .level(100))
        #expect(RoomModerationPolicy.actions(for: me, permissions: adminPerms).isEmpty)
    }

    @Test("power level hierarchy gates remove, ban, and unban strictly")
    func powerLevelHierarchy() {
        let modPerms = RoomModerationPermissions(canKick: true, canBan: true, ownPowerLevel: .level(50))
        let regularUser = member("@user:x.org", role: .user, power: .level(0))
        let peerMod = member("@mod:x.org", role: .moderator, power: .level(50))
        let admin = member("@admin:x.org", role: .administrator, power: .level(100))
        let creator = member("@creator:x.org", role: .administrator, power: .infinite)

        // Mod (50) can remove/ban regular user (0), but not equal mod (50), admin (100), or creator (infinite).
        let onUser = RoomModerationPolicy.actions(for: regularUser, permissions: modPerms)
        #expect(onUser == .init(canRemove: true, canBan: true, canUnban: false))
        #expect(RoomModerationPolicy.actions(for: peerMod, permissions: modPerms).isEmpty)
        #expect(RoomModerationPolicy.actions(for: admin, permissions: modPerms).isEmpty)
        #expect(RoomModerationPolicy.actions(for: creator, permissions: modPerms).isEmpty)

        // Admin (100) can moderate mod (50) but NOT room v12 creator (infinite).
        let adminPerms = RoomModerationPermissions(canKick: true, canBan: true, ownPowerLevel: .level(100))
        #expect(RoomModerationPolicy.actions(for: peerMod, permissions: adminPerms) == .init(canRemove: true, canBan: true, canUnban: false))
        #expect(RoomModerationPolicy.actions(for: creator, permissions: adminPerms).isEmpty)

        // Room v12 creator (infinite) can moderate admin (100), but not another creator (infinite).
        let creatorPerms = RoomModerationPermissions(canKick: true, canBan: true, ownPowerLevel: .infinite)
        #expect(RoomModerationPolicy.actions(for: admin, permissions: creatorPerms) == .init(canRemove: true, canBan: true, canUnban: false))
        #expect(RoomModerationPolicy.actions(for: creator, permissions: creatorPerms).isEmpty)
    }

    @Test("unban requires both ban and kick permissions and strictly higher power level")
    func unbanRequiresBothKickAndBan() {
        let bannedUser = member("@banned:x.org", power: .level(0), banned: true)
        let banOnly = RoomModerationPermissions(canKick: false, canBan: true, ownPowerLevel: .level(50))
        let kickOnly = RoomModerationPermissions(canKick: true, canBan: false, ownPowerLevel: .level(50))
        let both = RoomModerationPermissions(canKick: true, canBan: true, ownPowerLevel: .level(50))

        #expect(RoomModerationPolicy.actions(for: bannedUser, permissions: banOnly).isEmpty)
        #expect(RoomModerationPolicy.actions(for: bannedUser, permissions: kickOnly).isEmpty)
        #expect(RoomModerationPolicy.actions(for: bannedUser, permissions: both) == .init(canRemove: false, canBan: false, canUnban: true))
    }

    @Test("role labels distinguish Creator, Admin, Moderator, and regular user")
    func roleLabels() {
        #expect(RoomModerationPolicy.roleLabel(for: member("@c:x", role: .administrator, power: .infinite)) == "Creator")
        #expect(RoomModerationPolicy.roleLabel(for: member("@a:x", role: .administrator, power: .level(100))) == "Admin")
        #expect(RoomModerationPolicy.roleLabel(for: member("@m:x", role: .moderator, power: .level(50))) == "Moderator")
        #expect(RoomModerationPolicy.roleLabel(for: member("@u:x", role: .user, power: .level(0))) == nil)
    }

    @Test("refused and offline moderation errors explain clearly what failed")
    func errorMessages() {
        #expect(RoomModerationPolicy.errorMessage(for: .forbidden, action: .remove).contains("permission"))
        #expect(RoomModerationPolicy.errorMessage(for: .forbidden, action: .ban).contains("ban"))
        #expect(RoomModerationPolicy.errorMessage(for: .forbidden, action: .unban).contains("unban"))
        #expect(RoomModerationPolicy.errorMessage(for: .network(retryable: true), action: .ban).contains("offline"))
        #expect(RoomModerationPolicy.errorMessage(for: .notFound, action: .remove).contains("room"))
    }
}
