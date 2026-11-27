import Foundation
import HaloDomain
import HaloFoundation
import Testing

@Suite("ForwardPolicy & ForwardPayload (M20-6)")
struct ForwardingTests {
    @Test("warns only when forwarding from an encrypted source to one or more unencrypted targets")
    func encryptionDowngradeWarning() throws {
        let encA = ForwardTarget(id: try RoomID("!a:example.org"), name: "Secret", isEncrypted: true)
        let plainB = ForwardTarget(id: try RoomID("!b:example.org"), name: "General", isEncrypted: false)
        let plainC = ForwardTarget(id: try RoomID("!c:example.org"), name: "News", isEncrypted: false)

        // Encrypted → encrypted: no warning.
        #expect(ForwardPolicy.encryptionWarning(sourceIsEncrypted: true, targets: [encA]) == nil)
        // Unencrypted → unencrypted or encrypted: no warning.
        #expect(ForwardPolicy.encryptionWarning(sourceIsEncrypted: false, targets: [plainB, encA]) == nil)
        // Encrypted → single unencrypted target names it.
        let one = try #require(ForwardPolicy.encryptionWarning(sourceIsEncrypted: true, targets: [encA, plainB]))
        #expect(one.contains("General"))
        #expect(one.contains("isn't encrypted"))
        // Encrypted → multiple unencrypted targets lists count and names.
        let two = try #require(ForwardPolicy.encryptionWarning(sourceIsEncrypted: true, targets: [plainB, encA, plainC]))
        #expect(two.contains("2 unencrypted chats"))
        #expect(two.contains("General"))
        #expect(two.contains("News"))
    }

    @Test("payload previews describe every forwardable type clearly")
    func payloadSummaries() {
        let ref = MediaRef(token: "tok")
        #expect(ForwardPayload.text("  Hello\nworld ").previewSummary == "Hello world")
        #expect(ForwardPayload.image(ref: ref, filename: "p.jpg", mimeType: "image/jpeg", width: 10, height: 10, caption: nil).previewSummary == "Photo")
        #expect(ForwardPayload.image(ref: ref, filename: "p.jpg", mimeType: "image/jpeg", width: 10, height: 10, caption: "Sunset").previewSummary == "Sunset")
        #expect(ForwardPayload.video(ref: ref, filename: "v.mp4", mimeType: "video/mp4", duration: 3, width: 10, height: 20, caption: nil, thumbnailRef: nil).previewSummary == "Video")
        #expect(ForwardPayload.audio(ref: ref, filename: "v.m4a", mimeType: "audio/mp4", duration: 2, isVoice: true, waveform: nil).previewSummary == "Voice message")
        #expect(ForwardPayload.file(ref: ref, filename: "report.pdf", mimeType: "application/pdf").previewSummary == "report.pdf")
        #expect(ForwardPayload.sticker(body: "Cat", url: "mxc://x/1", info: nil).previewSummary == "Sticker: Cat")
        #expect(ForwardPayload.location(OutgoingLocation(latitude: 1, longitude: 2, description: "Cafe", isOwnLocation: false)).previewSummary == "Cafe")
    }
}
