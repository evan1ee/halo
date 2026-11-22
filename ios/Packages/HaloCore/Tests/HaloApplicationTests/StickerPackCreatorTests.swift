import Foundation
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Synchronization
import Testing
@testable import HaloApplication

@Suite("StickerPackCreator")
struct StickerPackCreatorTests {
    private struct Preparer: ImagePreparing {
        func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage {
            if data == Data("big".utf8) { return OutgoingImage(data: Data(count: StickerPackCreator.maximumImageBytes + 1), filename: filename, mimeType: "image/png", width: 512, height: 512) }
            guard data == Data("png".utf8) else { throw .invalidInput("NOT_AN_IMAGE") }
            return OutgoingImage(data: data, filename: "prepared.png", mimeType: "image/png", width: 512, height: 256)
        }
    }

    private func picked(_ code: String, _ data: String = "png") -> StickerPackCreator.Picked { .init(data: Data(data.utf8), filename: "\(code).heic", shortcode: code) }

    @Test("prepared images with their shortcodes go to the port, with progress")
    func creates() async throws {
        let port = FakeStickerPackCreation()
        let creator = StickerPackCreator(port: port, preparer: Preparer())
        let ticks = Mutex<[Int]>([])
        let ref = try await creator.create(name: "Cats", pictures: [picked("wave"), picked("dance")]) { done, _ in ticks.withLock { $0.append(done) } }
        #expect(port.created.count == 1 && port.created[0].name == "Cats")
        #expect(port.created[0].images.map(\.shortcode) == ["wave", "dance"] && port.created[0].images.allSatisfy { $0.width == 512 && $0.mimeType == "image/png" })
        #expect(ticks.withLock { $0 } == [1, 2] && ref.stateKey == ImagePackBuilder.stateKey)
    }

    @Test("bad input is refused before anything is created")
    func refuses() async {
        let port = FakeStickerPackCreation()
        let creator = StickerPackCreator(port: port, preparer: Preparer())
        await #expect(throws: HaloError.invalidInput("EMPTY_PACK_NAME")) { _ = try await creator.create(name: " ", pictures: [picked("a")]) { _, _ in } }
        await #expect(throws: HaloError.invalidInput("DUPLICATE_SHORTCODE")) { _ = try await creator.create(name: "x", pictures: [picked("a"), picked("a")]) { _, _ in } }
        await #expect(throws: HaloError.invalidInput("NOT_AN_IMAGE")) { _ = try await creator.create(name: "x", pictures: [picked("a", "text")]) { _, _ in } }
        await #expect(throws: HaloError.invalidInput("IMAGE_TOO_LARGE")) { _ = try await creator.create(name: "x", pictures: [picked("a", "big")]) { _, _ in } }
        #expect(port.created.isEmpty)
    }

    @Test("server errors pass through; shortcodes come from file names and stay unique")
    func errorsAndShortcodes() async {
        let port = FakeStickerPackCreation()
        port.fail(with: .network(retryable: true))
        await #expect(throws: HaloError.network(retryable: true)) { _ = try await StickerPackCreator(port: port, preparer: Preparer()).create(name: "x", pictures: [picked("a")]) { _, _ in } }
        #expect(StickerPackCreator.shortcode(forFilename: "Happy Cat.png", avoiding: []) == "Happy_Cat")
        #expect(StickerPackCreator.shortcode(forFilename: "Happy Cat.png", avoiding: ["Happy_Cat"]) == "Happy_Cat-2")
    }
}
