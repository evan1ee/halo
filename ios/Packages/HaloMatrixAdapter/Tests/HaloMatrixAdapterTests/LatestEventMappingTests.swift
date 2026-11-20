import Foundation
import HaloDomain
import MatrixRustSDK
import Testing
@testable import HaloMatrixAdapter

@Suite("RoomList latest event mapping")
struct LatestEventMappingTests {
    private func map(_ value: LatestEventValue) -> LatestEventRef? { MatrixRoomListPort.latestEvent(value) }

    @Test("a remote event keeps its time (milliseconds) and whether the user sent it")
    func remote() {
        let other = map(.remote(timestamp: 1_700_000_123_456, sender: "@b:x", isOwn: false, profile: .pending, content: .callInvite))
        #expect(other == LatestEventRef(timestamp: Date(timeIntervalSince1970: 1_700_000_123.456), senderIsSelf: false))
        let own = map(.remote(timestamp: 5_000, sender: "@a:x", isOwn: true, profile: .pending, content: .callInvite))
        #expect(own == LatestEventRef(timestamp: Date(timeIntervalSince1970: 5), senderIsSelf: true))
    }

    @Test("a local echo is the user's own event in every sending state")
    func local() {
        for state in [LatestEventValueLocalState.isSending, .hasBeenSent, .cannotBeSent] {
            let ref = map(.local(timestamp: 9_000, sender: "@a:x", profile: .pending, content: .callInvite, state: state))
            #expect(ref == LatestEventRef(timestamp: Date(timeIntervalSince1970: 9), senderIsSelf: true))
        }
    }

    @Test("rooms without events and invites have no latest event")
    func none() {
        #expect(map(.none) == nil)
        #expect(map(.remoteInvite(timestamp: 1_000, inviter: "@b:x", inviterProfile: .pending)) == nil)
    }
}
