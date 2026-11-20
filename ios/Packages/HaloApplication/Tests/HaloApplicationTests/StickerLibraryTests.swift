import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("StickerLibrary")
struct StickerLibraryTests {
    private let room = try! RoomID("!pack:x.org")
    private var ref: PackRef { PackRef(room: room, stateKey: "cats") }
    private func sticker(_ code: String) -> Sticker { Sticker(pack: ref, shortcode: code, body: nil, url: "mxc://x.org/\(code)", info: nil) }
    private func pack(_ codes: [String], usage: Set<PackUsage> = [.sticker]) -> StickerPack {
        StickerPack(ref: ref, displayName: "Cats", avatarURL: nil, usage: usage, attribution: nil, stickers: codes.map(sticker), source: .userEnabled)
    }

    private final class Time: Sendable {
        let instant = Mutex(ContinuousClock.now)
        let sleeps = Mutex<[Duration]>([])
        func advance(_ d: Duration) { instant.withLock { $0 = $0.advanced(by: d) } }
    }

    private func make(
        packs: StickerPackLoad = StickerPackLoad(packs: []), prefs: StickerPrefs? = nil
    ) -> (StickerLibrary, FakeStickerPacks, FakeStickerPrefs, Time) {
        let source = FakeStickerPacks(packs), store = FakeStickerPrefs(prefs), time = Time()
        let library = StickerLibrary(
            packs: source, prefs: store, now: { Date(timeIntervalSince1970: 1_000) }, clock: { time.instant.withLock { $0 } },
            sleep: { d in time.sleeps.withLock { $0.append(d) }; time.advance(d) })
        return (library, source, store, time)
    }

    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<200_000 { if condition() { return true }; await Task.yield() }
        return false
    }

    @Test("loading shows only sticker packs, with favourites and recents resolved against them")
    func loading() async throws {
        var prefs = StickerPrefs()
        prefs.toggleFavourite(sticker("b").ref)
        prefs.recordUse(sticker("a").ref, at: Date(timeIntervalSince1970: 1))
        prefs.toggleFavourite(sticker("gone").ref)
        let (library, source, _, _) = make(packs: StickerPackLoad(packs: [pack(["a", "b"]), pack(["e"], usage: [.emoticon])]), prefs: prefs)
        await library.load(currentRoom: room)
        let snapshot = await library.snapshots().first { _ in true }
        let s = try #require(snapshot)
        #expect(s.phase == .ready && s.packs.count == 1)
        #expect(s.favourites.map(\.shortcode) == ["b"] && s.recents.map(\.shortcode) == ["a"])
        #expect(s.unavailableFavourites.map(\.shortcode) == ["gone"])
        #expect(source.requests == [room])
    }

    @Test("a source that failed makes the panel partial; a total failure with nothing cached is failed")
    func partialAndFailed() async throws {
        let (library, source, _, _) = make(packs: StickerPackLoad(packs: [pack(["a"])], failedSources: 1))
        await library.load(currentRoom: nil)
        #expect(await library.snapshots().first { _ in true }?.phase == .partial)
        let (empty, failing, _, _) = make()
        failing.fail(with: .network(retryable: true))
        await empty.load(currentRoom: nil)
        #expect(await empty.snapshots().first { _ in true }?.phase == .failed)
        source.fail(with: .network(retryable: true))
        await library.load(currentRoom: nil)  // keeps what it had
        let after = await library.snapshots().first { _ in true }
        #expect(after?.phase == .partial && after?.packs.count == 1)
    }

    @Test("an enabled pack that can't be read is listed as unavailable and doesn't make the panel partial; reset forgets it")
    func unavailablePacks() async throws {
        let gone = PackRef(room: try RoomID("!gone:x.org"), stateKey: "old")
        let (library, _, _, _) = make(packs: StickerPackLoad(packs: [pack(["a"])], unavailable: [gone]))
        await library.load(currentRoom: nil)
        let snapshot = await library.snapshots().first { _ in true }
        #expect(snapshot?.phase == .ready && snapshot?.unavailablePacks == [gone] && snapshot?.packs.count == 1)
        await library.reset()
        #expect(await library.snapshots().first { _ in true }?.unavailablePacks == [])
    }

    @Test("removing unavailable packs disables each one and reloads for the same room")
    func removingUnavailable() async throws {
        let gone = PackRef(room: try RoomID("!gone:x.org"), stateKey: "old")
        let (library, source, _, _) = make(packs: StickerPackLoad(packs: [pack(["a"])], unavailable: [gone]))
        await library.load(currentRoom: room)
        await library.removeUnavailablePacks()
        #expect(source.disabled == [gone] && source.requests == [room, room])
    }

    @Test("recents are written at once the first time, then at most once per ten seconds with a trailing write")
    func debounce() async throws {
        let (library, _, store, time) = make(packs: StickerPackLoad(packs: [pack(["a", "b", "c"])]))
        await library.load(currentRoom: nil)
        await library.recordSent(sticker("a"))
        #expect(store.saves.count == 1)
        await library.recordSent(sticker("b"))
        await library.recordSent(sticker("c"))  // within the interval: one trailing write for both
        #expect(await eventually { store.saves.count == 2 })
        #expect(store.saves.last?.recents.map(\.sticker.shortcode).sorted() == ["a", "b", "c"])
        #expect(time.sleeps.withLock { $0 }.count == 1 && time.sleeps.withLock { $0 }[0] <= StickerLibrary.writeInterval)
    }

    @Test("flush sends a pending write, and a failed write is retried with the next one")
    func flushAndFailure() async throws {
        let (library, _, store, _) = make(packs: StickerPackLoad(packs: [pack(["a", "b"])]))
        await library.load(currentRoom: nil)
        store.setFailing(true)
        await library.recordSent(sticker("a"))
        #expect(store.saves.isEmpty)
        store.setFailing(false)
        await library.flush()
        #expect(store.saves.count == 1 && store.saves[0].recents.count == 1)
    }

    @Test("another device's recents are merged into the write, and a favourite removal is not undone by it")
    func mergesRemote() async throws {
        var remote = StickerPrefs()
        remote.recordUse(sticker("b").ref, at: Date(timeIntervalSince1970: 5))
        remote.toggleFavourite(sticker("a").ref)
        let (library, _, store, _) = make(packs: StickerPackLoad(packs: [pack(["a", "b"])]), prefs: remote)
        await library.load(currentRoom: nil)
        #expect(await library.isFavourite(sticker("a")))
        await library.toggleFavourite(sticker("a").ref)  // removed
        #expect(store.saves.last?.favourites.isEmpty == true)
        #expect(store.stored?.recents.map(\.sticker.shortcode) == ["b"])
        store.setRemote(store.stored)
        await library.recordSent(sticker("a"))
        #expect(await library.isFavourite(sticker("a")) == false)
    }

    @Test("search uses the loaded packs and prefs")
    func searching() async throws {
        let (library, _, _, _) = make(packs: StickerPackLoad(packs: [pack(["cat_wave", "dog"])]))
        await library.load(currentRoom: nil)
        #expect(await library.search("cat").map(\.shortcode) == ["cat_wave"])
    }

    @Test("reset forgets the previous account, so its favourites and recents are never written into the next one")
    func resetOnAccountChange() async throws {
        var mine = StickerPrefs()
        mine.toggleFavourite(sticker("a").ref)
        let (library, _, store, _) = make(packs: StickerPackLoad(packs: [pack(["a", "b"])]), prefs: mine)
        await library.load(currentRoom: room)
        await library.reset()
        let cleared = try #require(await library.snapshots().first { _ in true })
        #expect(cleared == StickerLibrary.Snapshot())
        store.setRemote(nil)  // the next account has no prefs yet
        await library.load(currentRoom: room)
        await library.recordSent(sticker("b"))
        let written = try #require(store.saves.last)
        #expect(written.favourites.isEmpty)
        #expect(written.recents.map(\.sticker.shortcode) == ["b"])
    }
}
