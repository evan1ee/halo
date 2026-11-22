import Foundation
import HaloDomain
import HaloFoundation
import Testing
@testable import HaloPlatform

@Suite("FileShareInbox")
struct FileShareInboxTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("share-inbox-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("staged items round-trip through pending() and data(of:)")
    func roundTrip() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        let staged = try inbox.stage([
            .text("hello"), .url("https://example.org"),
            .file(data: Data([1, 2, 3]), filename: "../evil/photo.jpg", mimeType: "image/jpeg", isImage: true),
        ])
        let pending = try inbox.pending()
        #expect(pending == [staged])
        let photo = try #require(pending.first?.items.last)
        #expect(photo.kind == .image && photo.filename == "photo.jpg" && photo.byteCount == 3)
        #expect(try inbox.data(of: photo, in: staged) == Data([1, 2, 3]))
        inbox.discard(staged)
        #expect(try inbox.pending().isEmpty)
    }

    @Test("an empty or oversized share is refused and leaves nothing behind")
    func refusals() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        #expect(throws: HaloError.invalidInput("SHARE_EMPTY")) { try inbox.stage([]) }
        let big = Data(count: FileShareInbox.maximumPayloadBytes + 1)
        #expect(throws: HaloError.invalidInput("SHARE_TOO_LARGE")) {
            try inbox.stage([.file(data: big, filename: "x", mimeType: "application/octet-stream", isImage: false)])
        }
        #expect(try inbox.pending().isEmpty)
    }

    @Test("expired payloads are deleted when listed; newer ones stay, oldest first")
    func expiry() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(Date(timeIntervalSince1970: 1_000_000))
        let inbox = FileShareInbox(directory: directory, now: { clock.value })
        let old = try inbox.stage([.text("old")])
        clock.value = clock.value.addingTimeInterval(SharePayload.lifetime - 10)
        let first = try inbox.stage([.text("first")])
        clock.value = clock.value.addingTimeInterval(5)
        let second = try inbox.stage([.text("second")])
        clock.value = clock.value.addingTimeInterval(20)  // `old` is now past its lifetime
        #expect(try inbox.pending() == [first, second])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(old.id).path))
    }

    @Test("a damaged payload folder is removed instead of failing the listing")
    func damaged() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        let good = try inbox.stage([.text("ok")])
        let broken = directory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        #expect(try inbox.pending() == [good])
        #expect(!FileManager.default.fileExists(atPath: broken.path))
    }

    @Test("an item that isn't in the payload can't be read")
    func foreignItem() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = FileShareInbox(directory: directory)
        let staged = try inbox.stage([.text("x")])
        let stranger = SharedItem(kind: .file, filename: "f")
        #expect(throws: HaloError.notFound) { try inbox.data(of: stranger, in: staged) }
    }
}

private final class Clock: @unchecked Sendable {  // test-only mutable clock, used from one thread
    var value: Date
    init(_ value: Date) { self.value = value }
}
