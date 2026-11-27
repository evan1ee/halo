import HaloDomain
import HaloFoundation
import Testing

@Suite("RoomLifecyclePolicy (M20-8)")
struct RoomLifecycleTests {
    @Test("maps every preview state cleanly into its screen presentation and actions")
    func previewPresentations() throws {
        let roomID = try RoomID("!room:example.org")

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: roomID.rawValue, membership: .joined, joinAccess: .inviteOnly
        )) == .alreadyJoined(roomID))

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: roomID.rawValue, membership: .invited, joinAccess: .inviteOnly
        )) == .invited(roomID))

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: "#lobby:example.org", membership: .knocked, joinAccess: .knock
        )) == .knocked(roomID))

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: "#lobby:example.org", membership: .banned, joinAccess: .public
        )) == .banned(roomID))

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: "#pub:example.org", membership: .left, joinAccess: .public
        )) == .left(roomID, canRejoin: true))

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: "#priv:example.org", membership: .left, joinAccess: .inviteOnly
        )) == .left(roomID, canRejoin: false))

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: "#pub:example.org", membership: nil, joinAccess: .public
        )) == .canJoin)

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: "#knock:example.org", membership: nil, joinAccess: .knock
        )) == .canKnock)

        #expect(RoomLifecyclePolicy.presentation(for: RoomLifecyclePreview(
            roomID: roomID, address: "#priv:example.org", membership: nil, joinAccess: .inviteOnly
        )) == .inviteOnly)
    }

    @Test("timeline banner prioritizes banned/left/knocked and shows successor for upgraded rooms")
    func timelineBanners() throws {
        let oldRoom = try RoomID("!old:example.org")
        let newRoom = try RoomID("!new:example.org")
        let successor = RoomSuccessor(roomID: newRoom, reason: "Upgraded to room v11")

        #expect(RoomLifecyclePolicy.banner(membership: .joined, successor: nil, roomID: oldRoom) == nil)
        #expect(RoomLifecyclePolicy.banner(membership: .joined, successor: successor, roomID: oldRoom) == .upgraded(successor))
        #expect(RoomLifecyclePolicy.banner(membership: .left, successor: successor, roomID: oldRoom) == .left(oldRoom))
        #expect(RoomLifecyclePolicy.banner(membership: .banned, successor: nil, roomID: oldRoom) == .banned(oldRoom))
        #expect(RoomLifecyclePolicy.banner(membership: .knocked, successor: nil, roomID: oldRoom) == .knocked(oldRoom))
    }

    @Test("RoomSuccessor trims blank reasons to nil")
    func successorReasonTrimming() throws {
        let id = try RoomID("!next:example.org")
        #expect(RoomSuccessor(roomID: id, reason: "   \n ").reason == nil)
        #expect(RoomSuccessor(roomID: id, reason: " Moved ").reason == "Moved")
    }
}
