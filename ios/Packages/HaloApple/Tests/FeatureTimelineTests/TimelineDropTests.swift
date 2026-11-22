import Testing
import UniformTypeIdentifiers
@testable import FeatureTimeline

@Suite("DropClassifier")
struct TimelineDropTests {
    private func kind(_ types: [UTType]) -> DropKind? { DropClassifier.kind(for: types.map(\.identifier)) }

    @Test("pictures become pending photos, even when the item also offers a file URL or raw data")
    func photos() {
        #expect(kind([.jpeg]) == .photo)
        #expect(kind([.png, .fileURL]) == .photo)
        #expect(kind([.heic, .data]) == .photo)
    }

    @Test("other files are sent as files")
    func files() {
        #expect(kind([.pdf]) == .file)
        #expect(kind([.fileURL]) == .file)
        #expect(kind([.zip, .data]) == .file)
    }

    @Test("text and links go into the draft")
    func text() {
        #expect(kind([.plainText]) == .text)
        #expect(kind([.url]) == .text)
        #expect(kind([.utf8PlainText]) == .text)
    }

    @Test("unknown or empty types are not accepted")
    func unknown() {
        #expect(DropClassifier.kind(for: []) == nil)
        #expect(DropClassifier.kind(for: ["not.a.type"]) == nil)
    }
}
