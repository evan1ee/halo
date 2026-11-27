#if canImport(UIKit)
import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Testing
import UIKit
@testable import FeatureTimeline

@MainActor
@Suite("ForwardSheet & ForwardViewModel (M20-6)")
struct ForwardSheetTests {
    @Test("warns before leaving an encrypted room and sends only after explicit confirmation")
    func warnsWhenLeavingEncryptedRoom() async throws {
        let encRoom = try RoomID("!enc:example.org")
        let plainRoom = try RoomID("!plain:example.org")
        let timeline = FakeTimelinePort()
        timeline.addRoom(encRoom)
        timeline.addRoom(plainRoom)
        let forwarder = ForwardCoordinator(timeline: timeline, media: FakeMediaPort())

        let vm = ForwardViewModel(
            payload: .text("Confidential"),
            forwarder: forwarder,
            loadTargets: {
                (
                    sourceIsEncrypted: true,
                    targets: [
                        ForwardTarget(id: encRoom, name: "Private Team", isEncrypted: true),
                        ForwardTarget(id: plainRoom, name: "Public Lobby", isEncrypted: false),
                    ]
                )
            }
        )
        await vm.load()
        vm.toggle(encRoom)
        vm.toggle(plainRoom)
        #expect(vm.selected == [encRoom, plainRoom])

        // First attempt stops at encryption warning — nothing sent yet!
        await vm.requestForward()
        #expect(vm.encryptionWarning?.contains("Public Lobby") == true)
        #expect(timeline.sentTexts(in: encRoom).isEmpty)
        #expect(timeline.sentTexts(in: plainRoom).isEmpty)
        #expect(!vm.completed)

        // Confirming sends to both rooms and completes.
        await vm.confirmForwardLeavingEncryption()
        #expect(vm.encryptionWarning == nil)
        #expect(vm.completed)
        #expect(timeline.sentTexts(in: encRoom) == ["Confidential"])
        #expect(timeline.sentTexts(in: plainRoom) == ["Confidential"])
    }

    @Test("forwarding between encrypted rooms sends without warning and partial failure keeps failed room selected for retry")
    func encryptedToEncryptedAndPartialRetry() async throws {
        let okRoom = try RoomID("!ok:example.org")
        let flakyRoom = try RoomID("!flaky:example.org")
        let timeline = FakeTimelinePort()
        timeline.addRoom(okRoom)
        timeline.addRoom(flakyRoom)
        timeline.failNextImage(with: .network(retryable: true), in: flakyRoom)
        let media = FakeMediaPort()
        let ref = MediaRef(token: "photo")
        media.add(ref, data: Data([0x89, 0x50, 0x4E, 0x47]))
        let forwarder = ForwardCoordinator(timeline: timeline, media: media)

        let vm = ForwardViewModel(
            payload: .image(ref: ref, filename: "p.png", mimeType: "image/png", width: 10, height: 10, caption: nil),
            forwarder: forwarder,
            loadTargets: {
                (
                    sourceIsEncrypted: true,
                    targets: [
                        ForwardTarget(id: okRoom, name: "Alice", isDirect: true, isEncrypted: true),
                        ForwardTarget(id: flakyRoom, name: "Bob", isDirect: true, isEncrypted: true),
                    ]
                )
            }
        )
        await vm.load()
        vm.toggle(okRoom)
        vm.toggle(flakyRoom)

        await vm.requestForward()
        #expect(vm.encryptionWarning == nil)
        #expect(!vm.completed)
        #expect(vm.selected == [flakyRoom], "only the failed target remains selected for retry")
        #expect(vm.errorMessage?.contains("Bob") == true)
        #expect(timeline.sentImages(in: okRoom).count == 1)
        #expect(timeline.sentImages(in: flakyRoom).isEmpty)

        // Retry sends only to flakyRoom (now succeeding) without duplicating to okRoom.
        await vm.requestForward()
        #expect(vm.completed)
        #expect(timeline.sentImages(in: okRoom).count == 1)
        #expect(timeline.sentImages(in: flakyRoom).count == 1)
    }

    @Test("TimelineViewModel maps forwardPayload for text, media, sticker, location and omits it for polls and redacted items")
    func mapsForwardPayloads() throws {
        let vm = TimelineViewModel(coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:x.org")))
        let sender = try UserID("@a:x.org")
        let ref = MediaRef(token: "m")
        func row(_ kind: TimelineEventKind) throws -> TimelineRow {
            vm.row(TimelineItem(
                id: TimelineItemID("1"),
                content: .event(TimelineEvent(
                    eventID: try EventID("$e1"), sender: sender, senderName: "A",
                    timestamp: Date(timeIntervalSince1970: 0), isOwn: false, kind: kind
                ))
            ))
        }

        #expect(try row(.text("Hi", isEdited: false)).forwardPayload == .text("Hi"))
        #expect(try row(.media(MediaAttachment(kind: .image, body: "Sunset", source: ref, width: 100, height: 80, mimeType: "image/jpeg"))).canForward)
        #expect(try row(.media(MediaAttachment(kind: .video, body: "v.mp4", source: ref, mimeType: "video/mp4"))).canForward)
        #expect(try row(.media(MediaAttachment(kind: .audio, body: "v.m4a", source: ref, mimeType: "audio/mp4", duration: 2, isVoice: true))).canForward)
        #expect(try row(.media(MediaAttachment(kind: .file, body: "doc.pdf", source: ref, mimeType: "application/pdf"))).canForward)
        #expect(try row(.sticker(body: "Cat", source: ref, url: "mxc://x/cat", info: nil)).forwardPayload == .sticker(body: "Cat", url: "mxc://x/cat", info: nil))
        #expect(try row(.location(body: "Cafe", geoURI: "geo:52.5,13.4")).canForward)
        #expect(try !row(.poll(PollDetails(question: "Q?", options: [PollOption(text: "A")]))).canForward)
        #expect(try !row(.redacted).canForward)
        #expect(try !row(.undecryptable(.unknown)).canForward)
    }

    @Test("ForwardSheet lays out cleanly in Light, Dark, and AX5")
    func forwardSheetLightDarkAX5() async throws {
        let r1 = try RoomID("!r1:example.org")
        let r2 = try RoomID("!r2:example.org")
        let forwarder = ForwardCoordinator(timeline: FakeTimelinePort(), media: FakeMediaPort())
        let vm = ForwardViewModel(
            payload: .image(ref: MediaRef(token: "t"), filename: "photo.jpg", mimeType: "image/jpeg", width: 100, height: 100, caption: "Architecture review notes"),
            forwarder: forwarder,
            loadTargets: {
                (
                    sourceIsEncrypted: true,
                    targets: [
                        ForwardTarget(id: r1, name: "Engineering Team", isEncrypted: true),
                        ForwardTarget(id: r2, name: "General Announcements", isEncrypted: false),
                    ]
                )
            }
        )
        await vm.load()
        vm.toggle(r1)
        vm.toggle(r2)

        let configs: [(name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]
        let outDir = ProcessInfo.processInfo.environment["HALO_FORWARD_SNAPSHOT_DIR"]

        for config in configs {
            let content = VStack(alignment: .leading, spacing: HaloSpacing.m) {
                Text("MESSAGE")
                    .font(HaloTypography.captionEmphasis)
                    .foregroundStyle(HaloColor.textSecondary)
                ForwardPreviewBanner(payload: vm.payload)
                    .padding(HaloSpacing.m)
                    .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous))

                Text("SEND TO")
                    .font(HaloTypography.captionEmphasis)
                    .foregroundStyle(HaloColor.textSecondary)
                VStack(spacing: HaloSpacing.s) {
                    ForEach(vm.targets) { target in
                        ForwardTargetRow(
                            target: target,
                            selected: vm.isSelected(target.id),
                            leavesEncryption: vm.sourceIsEncrypted && !target.isEncrypted,
                            disabled: false,
                            action: {}
                        )
                        .padding(.horizontal, HaloSpacing.m)
                        .padding(.vertical, HaloSpacing.xs)
                        .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous))
                    }
                }
            }
            .padding(16)
            .frame(width: 390, alignment: .leading)
            .background(HaloColor.bgPrimary)
            .environment(\.dynamicTypeSize, config.size)
            .environment(\.colorScheme, config.style == .dark ? .dark : .light)

            let host = UIHostingController(rootView: content)
            host.overrideUserInterfaceStyle = config.style
            let fitted = host.sizeThatFits(in: CGSize(width: 390, height: 10_000))
            #expect(fitted.width >= 350 && fitted.height >= 200)

            if let outDir {
                let renderer = ImageRenderer(content: content.frame(width: fitted.width, height: fitted.height))
                renderer.scale = 2
                if let uiImage = renderer.uiImage, let png = uiImage.pngData() {
                    let url = URL(fileURLWithPath: outDir).appendingPathComponent("forward-sheet-\(config.name).png")
                    try png.write(to: url)
                }
            }
        }
    }
}
#endif
