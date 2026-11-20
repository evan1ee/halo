import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureStickers

@MainActor
@Suite("StickerPanelViewModel")
struct StickerPanelViewModelTests {
    private let room = try! RoomID("!r:x.org")
    private var ref: PackRef { PackRef(room: try! RoomID("!pack:x.org"), stateKey: "cats") }
    private func sticker(_ code: String) -> Sticker { Sticker(pack: ref, shortcode: code, body: nil, url: "mxc://x.org/\(code)", info: nil) }

    private func make(
        send: @escaping @MainActor (Sticker) async throws(HaloError) -> Void = { _ in }
    ) -> (StickerPanelViewModel, FakeStickerPrefs) {
        let pack = StickerPack(ref: ref, displayName: "Cats", avatarURL: nil, usage: [.sticker], attribution: nil, stickers: ["cat_wave", "dog"].map(sticker), source: .userEnabled)
        let prefs = FakeStickerPrefs()
        let library = StickerLibrary(packs: FakeStickerPacks(StickerPackLoad(packs: [pack])), prefs: prefs)
        return (StickerPanelViewModel(library: library, room: room, send: send), prefs)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200_000 where !condition() { await Task.yield() }
    }

    @Test("the panel loads, shows the packs, and says when there is nothing")
    func loads() async {
        let (model, _) = make()
        #expect(model.emptyMessage == "Loading stickers…")
        await model.start()
        await settle { !model.snapshot.packs.isEmpty }
        #expect(model.snapshot.packs.map(\.displayName) == ["Cats"] && model.emptyMessage == nil)
        await model.stop()
        let empty = StickerPanelViewModel(library: StickerLibrary(packs: FakeStickerPacks(), prefs: FakeStickerPrefs()), room: nil, send: { _ in })
        await empty.start()
        await settle { empty.snapshot.phase == .ready }
        #expect(empty.emptyMessage == "No sticker packs yet.")
    }

    @Test("a tap sends the sticker once and records it as recent; the recents come back on the next open")
    func tapping() async {
        var sent: [String] = []
        let (model, prefs) = make(send: { sent.append($0.shortcode) })
        await model.start()
        await settle { !model.snapshot.packs.isEmpty }
        await model.tap(sticker("cat_wave"))
        #expect(sent == ["cat_wave"] && model.sendError == nil)
        await settle { model.snapshot.recents.count == 1 }
        #expect(model.snapshot.recents.map(\.shortcode) == ["cat_wave"])
        await model.stop()
        #expect(prefs.saves.last?.recents.count == 1)
    }

    @Test("a failed send keeps the sticker out of the recents and shows an honest error")
    func failing() async {
        let (model, prefs) = make(send: { (_: Sticker) async throws(HaloError) in throw HaloError.network(retryable: true) })
        await model.start()
        await settle { !model.snapshot.packs.isEmpty }
        await model.tap(sticker("dog"))
        #expect(model.sendError == "Can't reach the server. The sticker wasn't sent.")
        await model.stop()
        #expect(prefs.saves.isEmpty && model.snapshot.recents.isEmpty)
    }

    @Test("search shows matches and hides the sections; favourites toggle")
    func searchAndFavourite() async {
        let (model, _) = make()
        await model.start()
        await settle { !model.snapshot.packs.isEmpty }
        model.query = "cat"
        await settle { !model.results.isEmpty }
        #expect(model.isSearching && model.results.map(\.shortcode) == ["cat_wave"])
        model.query = "zzz"
        await settle { model.results.isEmpty }
        #expect(model.emptyMessage == "No stickers match “zzz”.")
        model.query = ""
        #expect(!model.isSearching)
        await model.toggleFavourite(sticker("dog"))
        await settle { model.isFavourite(sticker("dog")) }
        #expect(model.isFavourite(sticker("dog")) && model.snapshot.favourites.map(\.shortcode) == ["dog"])
        await model.stop()
    }
}
