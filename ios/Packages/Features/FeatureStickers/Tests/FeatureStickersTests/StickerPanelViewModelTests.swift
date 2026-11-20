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

    private struct Preparer: ImagePreparing {
        func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage {
            OutgoingImage(data: data, filename: filename, mimeType: "image/png", width: 512, height: 512)
        }
    }

    @Test("a new pack: shortcodes come from file names, problems are shown, create needs a name and valid unique shortcodes, and the panel reloads after")
    func newPack() async {
        let port = FakeStickerPackCreation()
        var reloaded = 0
        let model = NewPackViewModel(creator: StickerPackCreator(port: port, preparer: Preparer())) { reloaded += 1 }
        #expect(!model.canCreate)
        model.add(data: Data([1]), filename: "Happy Cat.png")
        model.add(data: Data([2]), filename: "Happy Cat.png")
        #expect(model.items.map(\.shortcode) == ["Happy_Cat", "Happy_Cat-2"])
        #expect(!model.canCreate)  // no name
        model.name = "Cats"
        #expect(model.canCreate)
        model.setShortcode("Happy_Cat", for: model.items[1])
        #expect(model.problem(with: model.items[1]) == "Another sticker has this name." && !model.canCreate)
        model.setShortcode("bad name", for: model.items[1])
        #expect(model.problem(with: model.items[1]) == "Use letters, digits, - and _ (up to 100)." && !model.canCreate)
        model.remove(model.items[1])
        #expect(model.canCreate)

        port.fail(with: .network(retryable: true))
        await model.create()
        #expect(model.phase == .failed("Can't reach the server. Nothing was created; try again.") && reloaded == 0)
        model.dismissError()
        #expect(model.phase == .editing && model.items.count == 1 && model.name == "Cats")  // nothing was lost

        port.fail(with: nil)
        await model.create()
        #expect(model.phase == .done && reloaded == 1)
        #expect(port.created.map(\.name) == ["Cats"] && port.created[0].images.map(\.shortcode) == ["Happy_Cat"])
    }

    @Test("the panel offers pack creation only when it was given the means")
    func panelCreation() async {
        let library = StickerLibrary(packs: FakeStickerPacks(), prefs: FakeStickerPrefs())
        let without = StickerPanelViewModel(library: library, room: nil, send: { _ in })
        #expect(!without.canCreatePack && without.beginNewPack() == nil)
        let creator = StickerPackCreator(port: FakeStickerPackCreation(), preparer: Preparer())
        let with = StickerPanelViewModel(library: library, room: nil, newPack: { done in NewPackViewModel(creator: creator, onCreated: done) }, send: { _ in })
        #expect(with.canCreatePack && with.beginNewPack() != nil)
    }

    @Test("the first sticker into an encrypted room waits for the one-time notice; after confirming it is sent and the notice stays acknowledged")
    func encryptionNotice() async {
        var sent: [String] = []
        var seen = false
        let pack = StickerPack(ref: ref, displayName: "Cats", avatarURL: nil, usage: [.sticker], attribution: nil, stickers: [sticker("cat_wave")], source: .userEnabled)
        let library = StickerLibrary(packs: FakeStickerPacks(StickerPackLoad(packs: [pack])), prefs: FakeStickerPrefs())
        let model = StickerPanelViewModel(
            library: library, room: room,
            notice: .init(roomIsEncrypted: { true }, isAcknowledged: { seen }, acknowledge: { seen = true }),
            send: { sent.append($0.shortcode) })
        await model.tap(sticker("cat_wave"))
        #expect(sent.isEmpty && model.pendingNotice?.shortcode == "cat_wave")
        model.cancelNotice()
        #expect(model.pendingNotice == nil && sent.isEmpty && !seen)
        await model.tap(sticker("cat_wave"))
        await model.confirmNotice()
        #expect(sent == ["cat_wave"] && seen && model.pendingNotice == nil)
        await model.tap(sticker("cat_wave"))
        #expect(sent == ["cat_wave", "cat_wave"] && model.pendingNotice == nil)
    }

    @Test("an unencrypted room never shows the notice")
    func plainRoom() async {
        var sent = 0
        let model = StickerPanelViewModel(
            library: StickerLibrary(packs: FakeStickerPacks(), prefs: FakeStickerPrefs()), room: room,
            notice: .init(roomIsEncrypted: { false }, isAcknowledged: { false }, acknowledge: {}), send: { _ in sent += 1 })
        await model.tap(sticker("x"))
        #expect(sent == 1 && model.pendingNotice == nil)
    }
}
