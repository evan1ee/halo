import Foundation
import HaloDomain
import HaloFoundation
import Synchronization
import Testing
@testable import HaloMatrixAdapter

@Suite("Room packs in the sticker panel")
struct RoomPackCacheTests {
    private final class Now: Sendable {
        let value = Mutex(Date(timeIntervalSince1970: 1_000))
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    @Test("a room's packs are kept for ten minutes, then read again")
    func lifetime() async throws {
        let now = Now()
        let cache = RoomPackCache(now: { now.value.withLock { $0 } })
        let room = try RoomID("!r:x.org")
        let pack = StickerPack(
            ref: PackRef(room: room, stateKey: ""), displayName: "Cats", avatarURL: nil, usage: [.sticker], attribution: nil, stickers: [],
            source: .room)
        #expect(await cache.packs(of: room) == nil)
        await cache.store([pack], for: room)
        now.advance(RoomPackCache.lifetime - 1)
        #expect(await cache.packs(of: room) == [pack])
        now.advance(1)
        #expect(await cache.packs(of: room) == nil)
    }

    @Test("only small rooms have their whole state read")
    func wholeState() {
        #expect(StickerRoomState.readsWholeState(joinedMembers: 2))
        #expect(StickerRoomState.readsWholeState(joinedMembers: StickerRoomState.wholeStateMemberLimit))
        #expect(!StickerRoomState.readsWholeState(joinedMembers: StickerRoomState.wholeStateMemberLimit + 1))
    }
}
