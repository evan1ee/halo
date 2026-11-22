import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing
@testable import FeatureTimeline

@Suite("TimelineDragExtractor")
struct TimelineDragTests {
    @Test("extracts text from messages, notices, emotes and photo captions")
    func extractsDraggableText() {
        let plain = TimelineRow(id: "1", style: .message, sender: "Alice", text: "Hello world")
        #expect(TimelineDragExtractor.text(for: plain) == "Hello world")

        let withSource = TimelineRow(
            id: "2", style: .ownMessage, sender: nil, text: "Hello (edited)",
            source: TimelineRow.Source(sender: "@me:x.org", eventID: nil, body: "Hello", formattedBody: "<b>Hello</b>")
        )
        #expect(TimelineDragExtractor.text(for: withSource) == "Hello")

        let caption = TimelineRow(
            id: "3", style: .message, sender: "Alice", text: "Sunset on the beach",
            image: .init(ref: MediaRef(token: "img"), aspectRatio: 4 / 3)
        )
        #expect(TimelineDragExtractor.text(for: caption) == "Sunset on the beach")

        let notice = TimelineRow(id: "4", style: .notice, sender: "Bot", text: "Build green")
        #expect(TimelineDragExtractor.text(for: notice) == "Build green")

        let emote = TimelineRow(id: "5", style: .emote, sender: "Alice", text: "Alice waves")
        #expect(TimelineDragExtractor.text(for: emote) == "Alice waves")
    }

    @Test("returns nil for non-text, sticker, file, filename-only photo, blank, and system rows")
    func ignoresNonDraggableRows() {
        let sticker = TimelineRow(
            id: "s", style: .message, sender: "Alice", text: "wave",
            image: .init(ref: MediaRef(token: "st"), aspectRatio: 1), isSticker: true
        )
        #expect(TimelineDragExtractor.text(for: sticker) == nil)

        let file = TimelineRow(
            id: "f", style: .message, sender: "Alice", text: "report.pdf",
            file: .init(kind: .file, name: "report.pdf", detail: "PDF", ref: MediaRef(token: "pdf"), size: 100, thumbnail: nil)
        )
        #expect(TimelineDragExtractor.text(for: file) == nil)

        let photoFilenameOnly = TimelineRow(
            id: "p", style: .message, sender: "Alice", text: "IMG_001.jpg",
            image: .init(ref: MediaRef(token: "img"), aspectRatio: 1)
        )
        #expect(TimelineDragExtractor.text(for: photoFilenameOnly) == nil)

        let blank = TimelineRow(id: "b", style: .message, sender: "Alice", text: "   \n ")
        #expect(TimelineDragExtractor.text(for: blank) == nil)

        for style: TimelineRow.Style in [.placeholder, .state, .divider, .marker] {
            let system = TimelineRow(id: "sys", style: style, sender: nil, text: "Joined")
            #expect(TimelineDragExtractor.text(for: system) == nil)
        }
    }

    @Test("allows photo drag only for loaded non-sticker images")
    func photoDragEligibility() {
        #expect(TimelineDragExtractor.allowsPhotoDrag(isSticker: false, hasImageData: true))
        #expect(!TimelineDragExtractor.allowsPhotoDrag(isSticker: true, hasImageData: true))
        #expect(!TimelineDragExtractor.allowsPhotoDrag(isSticker: false, hasImageData: false))
    }

    @Test("allows file drag up to the 50 MB limit")
    func fileDragEligibility() {
        #expect(TimelineDragExtractor.allowsFileDrag(size: nil))
        #expect(TimelineDragExtractor.allowsFileDrag(size: 1024))
        #expect(TimelineDragExtractor.allowsFileDrag(size: TimelineViewModel.openSizeLimit))
        #expect(!TimelineDragExtractor.allowsFileDrag(size: TimelineViewModel.openSizeLimit + 1))
    }

    @MainActor
    @Test("downloadFileToTemp writes sanitized file and rejects oversized attachments")
    func downloadFileToTemp() async throws {
        let ref = MediaRef(token: "doc-1")
        let port = FakeMediaPort()
        port.add(ref, data: Data("hello pdf".utf8))
        let model = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")),
            media: MediaLoader(port: port)
        )
        let tile = TimelineRow.FileTile(kind: .file, name: "../../secret.pdf", detail: "PDF", ref: ref, size: 9, thumbnail: nil)
        let url = try await model.downloadFileToTemp(tile)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "secret.pdf")
        #expect(try Data(contentsOf: url) == Data("hello pdf".utf8))

        let huge = TimelineRow.FileTile(
            kind: .file, name: "huge.bin", detail: "BIN", ref: ref,
            size: TimelineViewModel.openSizeLimit + 1, thumbnail: nil
        )
        await #expect(throws: HaloError.self) {
            _ = try await model.downloadFileToTemp(huge)
        }
    }
}
