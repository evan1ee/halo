import FeatureStickers
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@Suite("StickerLibraryViewModel")
@MainActor
struct StickerLibraryViewModelTests {
    private struct PassThroughPreparer: ImagePreparing {
        func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage {
            OutgoingImage(data: data, filename: filename, mimeType: "image/png", width: 512, height: 512)
        }
    }

    @Test("manages packs end-to-end with unique shortcodes on add")
    func managesPacks() async throws {
        let ref = PackRef(room: try RoomID("!pack:x.org"), stateKey: "pack")
        let initial = Sticker(pack: ref, shortcode: "cat", body: "cat", url: "mxc://x/cat", info: nil)
        let pack = StickerPack(ref: ref, displayName: "Cats", avatarURL: nil, usage: [.sticker], attribution: nil, stickers: [initial], source: .userEnabled)

        let packsPort = FakeStickerPacks(StickerPackLoad(packs: [pack]))
        let managementPort = FakeStickerPackManagement(backing: packsPort)
        let library = StickerLibrary(packs: packsPort, prefs: FakeStickerPrefs())
        let manager = StickerPackManager(port: managementPort, preparer: PassThroughPreparer(), library: library)
        let vm = StickerLibraryViewModel(library: library, manager: manager)

        await vm.start()
        defer { vm.stop() }
        await Task.yield()

        #expect(vm.packs.count == 1)
        #expect(vm.packs.first?.displayName == "Cats")

        let renamed = await vm.rename(ref, to: "Felines")
        #expect(renamed)
        await Task.yield()
        #expect(vm.pack(for: ref)?.displayName == "Felines")

        // Adding a file named "cat.png" avoids colliding with existing "cat" shortcode.
        let added = await vm.addStickers(to: ref, files: [(data: Data([1, 2, 3]), filename: "cat.png")])
        #expect(added)
        await Task.yield()
        #expect(vm.pack(for: ref)?.stickers.map(\.shortcode) == ["cat", "cat-2"])

        let removed = await vm.removeSticker(shortcode: "cat", from: ref)
        #expect(removed)
        await Task.yield()
        #expect(vm.pack(for: ref)?.stickers.map(\.shortcode) == ["cat-2"])

        let deleted = await vm.deletePack(ref)
        #expect(deleted)
        await Task.yield()
        #expect(vm.packs.isEmpty)
    }

    @Test("surfaces permission error without crashing")
    func surfacesError() async throws {
        let ref = PackRef(room: try RoomID("!pack:x.org"), stateKey: "pack")
        let pack = StickerPack(ref: ref, displayName: "Shared", avatarURL: nil, usage: [.sticker], attribution: nil, stickers: [], source: .userEnabled)

        let packsPort = FakeStickerPacks(StickerPackLoad(packs: [pack]))
        let managementPort = FakeStickerPackManagement(backing: packsPort)
        managementPort.fail(with: .forbidden)
        let library = StickerLibrary(packs: packsPort, prefs: FakeStickerPrefs())
        let manager = StickerPackManager(port: managementPort, preparer: PassThroughPreparer(), library: library)
        let vm = StickerLibraryViewModel(library: library, manager: manager)

        await vm.start()
        defer { vm.stop() }
        let ok = await vm.rename(ref, to: "New")
        #expect(!ok)
        #expect(vm.error == "You don't have permission to edit this pack.")
    }

    @Test("surfaces loadFailed on initial load failure and recovers on reload (M21-1)")
    func surfacesLoadFailureAndRecovers() async throws {
        let ref = PackRef(room: try RoomID("!pack:x.org"), stateKey: "pack")
        let pack = StickerPack(ref: ref, displayName: "Cats", avatarURL: nil, usage: [.sticker], attribution: nil, stickers: [], source: .userEnabled)

        let packsPort = FakeStickerPacks(StickerPackLoad(packs: [pack]))
        packsPort.fail(with: .network(retryable: true))
        let managementPort = FakeStickerPackManagement(backing: packsPort)
        let library = StickerLibrary(packs: packsPort, prefs: FakeStickerPrefs())
        let manager = StickerPackManager(port: managementPort, preparer: PassThroughPreparer(), library: library)
        let vm = StickerLibraryViewModel(library: library, manager: manager)

        await vm.start()
        defer { vm.stop() }
        await Task.yield()

        #expect(vm.packs.isEmpty)
        #expect(vm.loadFailed)

        packsPort.fail(with: nil)
        await vm.reload()
        await Task.yield()

        #expect(!vm.loadFailed)
        #expect(vm.packs.count == 1)
    }
}
