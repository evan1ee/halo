import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import FeatureTimeline

private struct FakeVideoPreparer: VideoPreparing {
    let width: Int
    let height: Int
    let duration: TimeInterval
    let error: HaloError?

    init(width: Int = 1080, height: Int = 1920, duration: TimeInterval = 12.0, error: HaloError? = nil) {
        self.width = width
        self.height = height
        self.duration = duration
        self.error = error
    }

    func prepare(fileURL: URL, filename: String, mimeType: String) async throws(HaloError) -> OutgoingFile {
        if let error { throw error }
        let thumb = OutgoingImage.Thumbnail(data: Data([0xFF, 0xD8, 0xFF]), mimeType: "image/jpeg", width: 180, height: 320)
        let outgoing = OutgoingFile(
            data: Data(), filename: filename, mimeType: mimeType, duration: duration,
            fileURL: fileURL, width: width, height: height, caption: nil, thumbnail: thumb
        )
        try outgoing.validate()
        return outgoing
    }
}

@Suite("Video poster, full-screen streaming, and caption sending (M20-3)")
@MainActor
struct VideoPlaybackAndSendTests {
    private func makeVideoRow(
        id: String = "v1",
        ref: MediaRef = MediaRef(token: "vid-1"),
        filename: String = "Sunset clip",
        caption: String? = "Golden hour",
        mimeType: String? = "video/mp4",
        size: Int? = 2_500_000,
        duration: TimeInterval? = 18,
        width: Int? = 1920,
        height: Int? = 1080
    ) throws -> TimelineRow {
        let ratio = VideoDisplayMetrics.aspectRatio(width: width, height: height)
        return TimelineRow(
            id: id, style: .message, sender: "Alice", text: "[Video] \(caption ?? filename)",
            eventID: try EventID("$\(id)"), isOwn: false,
            video: .init(
                ref: ref, filename: filename, caption: caption, mimeType: mimeType,
                size: size, duration: duration, aspectRatio: ratio, thumbnail: nil, blurhash: nil, isOwn: false)
        )
    }

    @Test("openVideo streams via MediaPort.file (never memory), sets openedVideo, and closeVideo deletes temp folder")
    func openAndCloseStreamsFromFile() async throws {
        let room = try RoomID("!video:example.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let media = FakeMediaPort()
        let ref = MediaRef(token: "vid-stream")
        media.add(ref, data: Data("mp4-bytes".utf8))

        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room),
            media: MediaLoader(port: media)
        )
        let row = try makeVideoRow(ref: ref, filename: "Beach clip", caption: "At the beach", mimeType: "video/quicktime")

        await vm.openVideo(row)
        let opened = try #require(vm.openedVideo)
        #expect(media.fileCalls == 1)
        #expect(media.contentCalls == 0)
        #expect(opened.url.lastPathComponent == "Beach clip.mov")
        #expect(opened.title == "Alice")
        #expect(opened.caption == "At the beach")
        #expect(FileManager.default.fileExists(atPath: opened.url.path))

        let dir = opened.url.deletingLastPathComponent()
        vm.closeVideo()
        #expect(vm.openedVideo == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("cancelOpenVideo cancels an in-flight download with no error and cleans up; oversized & offline fail honestly")
    func cancelOversizedAndOfflineErrors() async throws {
        let room = try RoomID("!video2:example.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let media = FakeMediaPort()
        let ref = MediaRef(token: "vid-cancel")
        media.add(ref, data: Data("bytes".utf8))
        media.holdNextFile()

        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room),
            media: MediaLoader(port: media)
        )
        let row = try makeVideoRow(ref: ref)

        let openTask = Task { await vm.openVideo(row) }
        for _ in 0..<200 where vm.openingVideoRow == nil { await Task.yield() }
        #expect(vm.openingVideoRow == row.id)

        vm.cancelOpenVideo()
        media.releaseHeldFile()
        await openTask.value
        #expect(vm.openingVideoRow == nil)
        #expect(vm.openedVideo == nil)
        #expect(vm.openFileError == nil)

        // Oversized video refuses without calling MediaPort.file.
        let huge = try makeVideoRow(id: "huge", ref: ref, size: TimelineViewModel.openSizeLimit + 1)
        await vm.openVideo(huge)
        #expect(vm.openedVideo == nil)
        #expect(vm.openFileError?.contains("too large") == true)
        vm.dismissOpenFileError()

        // Network error shows honest offline message.
        media.failNext(with: .network(retryable: true))
        await vm.openVideo(row)
        #expect(vm.openedVideo == nil)
        #expect(vm.openFileError == "Can't reach the server. The video wasn't opened.")
    }

    @Test("video preview policy hides poster until revealed")
    func previewPolicyGating() async throws {
        let room = try RoomID("!priv:example.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room),
            previewsAllowed: { false }
        )
        await vm.start()
        let row = try makeVideoRow()
        let video = try #require(row.video)
        #expect(!vm.showsPreview(of: video))
        vm.revealPreview(of: video)
        #expect(vm.showsPreview(of: video))
        await vm.stop()
    }

    @Test("pending videos send with caption, portrait/landscape metadata, poster thumbnail, and clean up staged files")
    func stageAndSendVideoWithCaption() async throws {
        let room = try RoomID("!sendvid:example.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room),
            videos: FakeVideoPreparer(width: 1080, height: 1920, duration: 9.5)
        )
        await vm.start()

        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-src-vid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let srcURL = srcDir.appendingPathComponent("portrait.mov")
        try Data("fake-mov-data".utf8).write(to: srcURL)

        await vm.attachVideo(fileURL: srcURL, filename: "portrait.mov", mimeType: "video/quicktime")
        #expect(vm.pendingVideos.count == 1)
        #expect(vm.canSend)
        let stagedURL = try #require(vm.pendingVideos.first?.fileURL)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))

        vm.draft = "Portrait demo"
        await vm.send()

        #expect(vm.pendingVideos.isEmpty)
        #expect(vm.draft.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.deletingLastPathComponent().path))

        let sent = port.sentFiles(in: room)
        #expect(sent.count == 1)
        #expect(sent[0].kind == .video)
        #expect(sent[0].caption == "Portrait demo")
        #expect(sent[0].width == 1080 && sent[0].height == 1920)
        #expect(sent[0].duration == 9.5)
        #expect(sent[0].thumbnail != nil)
        await vm.stop()
    }

    #if canImport(UIKit)
    @Test("VideoPosterView lays out portrait and landscape posters cleanly in Light, Dark, and AX5")
    func videoPosterLayoutLightDarkAX5() async throws {
        let room = try RoomID("!vui:example.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let vm = TimelineViewModel(coordinator: TimelineCoordinator(port: port, room: room))

        let landscapeRow = try makeVideoRow(
            id: "land", filename: "ocean.mp4", caption: "Sunset over the bay",
            size: 14_200_000, duration: 84, width: 1920, height: 1080)
        let portraitRow = try makeVideoRow(
            id: "port", filename: "vertical.mov", caption: nil,
            size: 8_400_000, duration: 15, width: 1080, height: 1920)
        let loadingRow = try makeVideoRow(
            id: "load", filename: "big.mp4", caption: nil,
            size: 98_000_000, duration: 240, width: 1920, height: 1080)

        let landscapeVideo = try #require(landscapeRow.video)
        let portraitVideo = try #require(portraitRow.video)
        let loadingVideo = try #require(loadingRow.video)

        let configs: [(name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]
        let outDir = ProcessInfo.processInfo.environment["HALO_VIDEO_SNAPSHOT_DIR"]

        for config in configs {
            let content = VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    VideoPosterView(
                        row: landscapeRow, video: landscapeVideo, isOpening: false,
                        model: vm, isOwn: true, open: {}, cancel: {})
                }
                VideoPosterView(
                    row: portraitRow, video: portraitVideo, isOpening: false,
                    model: vm, isOwn: false, open: {}, cancel: {})
                VideoPosterView(
                    row: loadingRow, video: loadingVideo, isOpening: true,
                    model: vm, isOwn: false, open: {}, cancel: {})
            }
            .padding(16)
            .frame(width: 390, alignment: .leading)
            .background(HaloColor.bgPrimary)
            .environment(\.dynamicTypeSize, config.size)
            .environment(\.colorScheme, config.style == .dark ? .dark : .light)

            let host = UIHostingController(rootView: content)
            host.overrideUserInterfaceStyle = config.style
            let fitted = host.sizeThatFits(in: CGSize(width: 390, height: 1600))
            #expect(fitted.width >= 350 && fitted.height >= 400)

            if let outDir {
                let renderer = ImageRenderer(content: content.frame(width: fitted.width, height: fitted.height))
                renderer.scale = 2
                if let uiImage = renderer.uiImage, let png = uiImage.pngData() {
                    let url = URL(fileURLWithPath: outDir).appendingPathComponent("video-poster-\(config.name).png")
                    try png.write(to: url)
                }
            }
        }
    }
    #endif
}
