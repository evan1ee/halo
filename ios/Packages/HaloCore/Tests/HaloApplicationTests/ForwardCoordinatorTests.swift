import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloTestSupport
import Testing

@Suite("ForwardCoordinator (M20-6)")
struct ForwardCoordinatorTests {
    @Test("forwards text, photo, video, audio, file, sticker, and location to multiple unique targets, downloading media once")
    func forwardsAllTypesToMultipleTargets() async throws {
        let roomA = try RoomID("!a:example.org")
        let roomB = try RoomID("!b:example.org")
        let timeline = FakeTimelinePort()
        timeline.addRoom(roomA)
        timeline.addRoom(roomB)
        let media = FakeMediaPort()
        let imgRef = MediaRef(token: "img")
        let vidRef = MediaRef(token: "vid")
        let thumbRef = MediaRef(token: "thumb")
        let audioRef = MediaRef(token: "aud")
        let fileRef = MediaRef(token: "doc")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        media.add(imgRef, data: png)
        media.add(vidRef, data: Data("video-bytes".utf8))
        media.add(thumbRef, data: png)
        media.add(audioRef, data: Data("voice-bytes".utf8))
        media.add(fileRef, data: Data("pdf-bytes".utf8))

        let coordinator = ForwardCoordinator(timeline: timeline, media: media)

        // Text to two targets (plus duplicate roomA deduplicated).
        let textOutcome = await coordinator.forward(.text("Forwarded note"), to: [roomA, roomB, roomA])
        #expect(textOutcome.isCompleteSuccess)
        #expect(textOutcome.succeeded == [roomA, roomB])
        #expect(timeline.sentTexts(in: roomA) == ["Forwarded note"])
        #expect(timeline.sentTexts(in: roomB) == ["Forwarded note"])

        // Image with caption (downloaded once, sent to both rooms).
        let imgOutcome = await coordinator.forward(
            .image(ref: imgRef, filename: "pic.png", mimeType: nil, width: 100, height: 80, caption: "Check this"),
            to: [roomA, roomB]
        )
        #expect(imgOutcome.isCompleteSuccess)
        #expect(media.contentCalls == 1)
        #expect(timeline.sentImages(in: roomA).first?.mimeType == "image/png")
        #expect(timeline.sentImages(in: roomA).first?.caption == "Check this")
        #expect(timeline.sentImages(in: roomB).first?.data == png)

        // Video with thumbnail, audio voice note, and generic file.
        let vidOutcome = await coordinator.forward(
            .video(ref: vidRef, filename: "clip.mp4", mimeType: "video/mp4", duration: 4.0, width: 720, height: 1280, caption: "Clip", thumbnailRef: thumbRef),
            to: [roomA, roomB]
        )
        #expect(vidOutcome.isCompleteSuccess)
        #expect(timeline.sentFiles(in: roomA).first?.kind == .video)
        #expect(timeline.sentFiles(in: roomA).first?.caption == "Clip")
        #expect(timeline.sentFiles(in: roomA).first?.thumbnail?.data == png)

        let audioOutcome = await coordinator.forward(
            .audio(ref: audioRef, filename: "voice.m4a", mimeType: "audio/mp4", duration: 3.5, isVoice: true, waveform: [0.2, 0.8]),
            to: [roomA]
        )
        #expect(audioOutcome.isCompleteSuccess)
        #expect(timeline.sentFiles(in: roomA).last?.isVoiceMessage == true)
        #expect(timeline.sentFiles(in: roomA).last?.waveform == [0.2, 0.8])

        let fileOutcome = await coordinator.forward(
            .file(ref: fileRef, filename: "notes.pdf", mimeType: "application/pdf"),
            to: [roomB]
        )
        #expect(fileOutcome.isCompleteSuccess)
        #expect(timeline.sentFiles(in: roomB).last?.filename == "notes.pdf")

        // Sticker and location.
        let stickerOutcome = await coordinator.forward(
            .sticker(body: "Cat", url: "mxc://example.org/cat1", info: StickerInfo(width: 256, height: 256, mimeType: "image/png")),
            to: [roomA, roomB]
        )
        #expect(stickerOutcome.isCompleteSuccess)
        #expect(timeline.sentStickers(in: roomA).first?.url == "mxc://example.org/cat1")
        #expect(timeline.sentStickers(in: roomB).first?.eventBody == "Cat")

        let loc = OutgoingLocation(latitude: 52.5, longitude: 13.4, description: "Berlin", isOwnLocation: false)
        let locOutcome = await coordinator.forward(.location(loc), to: [roomA, roomB])
        #expect(locOutcome.isCompleteSuccess)
        #expect(timeline.sentLocations(in: roomA) == [loc])
        #expect(timeline.sentLocations(in: roomB) == [loc])
    }

    @Test("reports partial failures per target without hiding succeeded rooms")
    func partialFailureAcrossTargets() async throws {
        let good = try RoomID("!good:example.org")
        let bad = try RoomID("!bad:example.org")
        let timeline = FakeTimelinePort()
        timeline.addRoom(good)
        timeline.addRoom(bad)
        timeline.failNextImage(with: .network(retryable: true), in: bad)

        let media = FakeMediaPort()
        let ref = MediaRef(token: "img")
        media.add(ref, data: Data([0xFF, 0xD8, 0xFF, 0xE0]))

        let coordinator = ForwardCoordinator(timeline: timeline, media: media)
        let outcome = await coordinator.forward(
            .image(ref: ref, filename: "p.jpg", mimeType: "image/jpeg", width: 10, height: 10, caption: nil),
            to: [good, bad]
        )
        #expect(!outcome.isCompleteSuccess)
        #expect(outcome.succeeded == [good])
        #expect(outcome.failed[bad] == .network(retryable: true))
    }
}
