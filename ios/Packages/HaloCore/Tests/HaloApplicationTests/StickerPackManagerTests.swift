import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@Suite("StickerPackManager")
struct StickerPackManagerTests {
    private struct PassThroughPreparer: ImagePreparing {
        func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage {
            OutgoingImage(data: data, filename: filename, mimeType: "image/png", width: 512, height: 512)
        }
    }

    @Test("rename, add, removeSticker, and deletePack update backing packs and reload library")
    func fullLifecycle() async throws {
        let ref = PackRef(room: try RoomID("!pack:x.org"), stateKey: "pack")
        let initialSticker = Sticker(pack: ref, shortcode: "hi", body: "Hi", url: "mxc://x/hi", info: nil)
        let pack = StickerPack(ref: ref, displayName: "Cats", avatarURL: nil, usage: [.sticker], attribution: nil, stickers: [initialSticker], source: .userEnabled)

        let packsPort = FakeStickerPacks(StickerPackLoad(packs: [pack]))
        let managementPort = FakeStickerPackManagement(backing: packsPort)
        let library = StickerLibrary(packs: packsPort, prefs: FakeStickerPrefs())
        let manager = StickerPackManager(port: managementPort, preparer: PassThroughPreparer(), library: library)

        await library.load(currentRoom: nil)

        try await manager.rename(ref, to: "Cute Cats")
        var snapshot = await library.snapshots().first { _ in true }
        #expect(snapshot?.packs.first?.displayName == "Cute Cats")

        let picked = StickerPackCreator.Picked(data: Data([1, 2, 3]), filename: "wave.png", shortcode: "wave")
        try await manager.addStickers(to: ref, existingShortcodes: ["hi"], pictures: [picked]) { _, _ in }
        snapshot = await library.snapshots().first { _ in true }
        #expect(snapshot?.packs.first?.stickers.map(\.shortcode) == ["hi", "wave"])

        try await manager.removeSticker(shortcode: "hi", from: ref)
        snapshot = await library.snapshots().first { _ in true }
        #expect(snapshot?.packs.first?.stickers.map(\.shortcode) == ["wave"])

        try await manager.deletePack(ref)
        snapshot = await library.snapshots().first { _ in true }
        #expect(snapshot?.packs.isEmpty == true)
    }
}
