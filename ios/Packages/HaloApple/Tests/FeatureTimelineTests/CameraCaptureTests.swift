#if canImport(UIKit)
import Foundation
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import FeatureTimeline

private final class FakeCameraAuthorizer: CameraAuthorizing {
    struct State: Sendable {
        var available: Bool
        var status: CameraAuthorizationStatus
        var grantOnRequest: Bool
        var requestCount: Int = 0
    }

    private let state: Mutex<State>

    init(available: Bool = true, status: CameraAuthorizationStatus = .notDetermined, grantOnRequest: Bool = true) {
        self.state = Mutex(State(available: available, status: status, grantOnRequest: grantOnRequest))
    }

    var isCameraAvailable: Bool { state.withLock(\.available) }
    var requestCount: Int { state.withLock(\.requestCount) }

    func authorizationStatus() -> CameraAuthorizationStatus { state.withLock(\.status) }

    func requestAccess() async -> Bool {
        state.withLock { s in
            s.requestCount += 1
            if s.grantOnRequest {
                s.status = .authorized
                return true
            } else {
                s.status = .denied
                return false
            }
        }
    }
}

private struct StrippingImagePreparer: ImagePreparing {
    let onPrepare: @Sendable (String) -> Void

    func prepare(data: Data, filename: String) throws(HaloError) -> OutgoingImage {
        onPrepare(filename)
        return OutgoingImage(data: Data("clean-jpeg".utf8), filename: "camera.jpg", mimeType: "image/jpeg", width: 120, height: 80)
    }
}

private struct StrippingVideoPreparer: VideoPreparing {
    func prepare(fileURL: URL, filename: String, mimeType: String) async throws(HaloError) -> OutgoingFile {
        // Simulates VideoPreparer writing a GPS-stripped file into a fresh halo-pending-video-clean-* directory.
        let cleanDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-pending-video-clean-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: cleanDir, withIntermediateDirectories: true)
            let cleanURL = cleanDir.appendingPathComponent(filename)
            try Data("clean-video".utf8).write(to: cleanURL)
            return OutgoingFile(
                data: Data(), filename: filename, mimeType: mimeType,
                duration: 3.0, fileURL: cleanURL, width: 1080, height: 1920
            )
        } catch {
            throw .internal(code: "TEST_CLEAN_WRITE")
        }
    }
}

@MainActor
@Suite("Camera capture & permissions (M20-5)")
struct CameraCaptureTests {
    @Test("permission is requested only in context, not on controller creation")
    func permissionAskedInContext() async {
        let auth = FakeCameraAuthorizer(available: true, status: .notDetermined, grantOnRequest: true)
        let controller = CameraPermissionController(authorizer: auth)
        #expect(auth.requestCount == 0)
        #expect(!controller.isPresentingCamera)
        #expect(controller.statusSheet == nil)

        await controller.openCamera()
        #expect(auth.requestCount == 1)
        #expect(controller.isPresentingCamera)
        #expect(controller.statusSheet == nil)

        // Subsequent open when already authorized does not re-prompt.
        controller.dismissCamera()
        await controller.openCamera()
        #expect(auth.requestCount == 1)
        #expect(controller.isPresentingCamera)
    }

    @Test("denying camera permission transitions to denied state with Open Settings")
    func deniedPermissionState() async {
        let auth = FakeCameraAuthorizer(available: true, status: .notDetermined, grantOnRequest: false)
        let controller = CameraPermissionController(authorizer: auth)

        await controller.openCamera()
        #expect(auth.requestCount == 1)
        #expect(!controller.isPresentingCamera)
        #expect(controller.statusSheet == .denied(canOpenSettings: true))

        // Tapping again while denied does not re-request system permission.
        controller.dismissStatusSheet()
        await controller.openCamera()
        #expect(auth.requestCount == 1)
        #expect(controller.statusSheet == .denied(canOpenSettings: true))
    }

    @Test("restricted and unavailable states are honest and never prompt")
    func restrictedAndUnavailableStates() async {
        let restrictedAuth = FakeCameraAuthorizer(available: true, status: .restricted)
        let restricted = CameraPermissionController(authorizer: restrictedAuth)
        await restricted.openCamera()
        #expect(restrictedAuth.requestCount == 0)
        #expect(restricted.statusSheet == .denied(canOpenSettings: false))

        let noHardware = FakeCameraAuthorizer(available: false, status: .notDetermined)
        let unavailable = CameraPermissionController(authorizer: noHardware)
        await unavailable.openCamera()
        #expect(noHardware.requestCount == 0)
        #expect(unavailable.statusSheet == .unavailable)
    }

    @Test("camera captures run through image/video preparers and clean up replaced temp folders")
    func cameraCapturesPrepareAndCleanUp() async throws {
        let room = try RoomID("!cam:example.org")
        let port = FakeTimelinePort()
        port.addRoom(room)
        let preparedFilenames = Mutex<[String]>([])
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: port, room: room),
            images: StrippingImagePreparer { name in preparedFilenames.withLock { $0.append(name) } },
            videos: StrippingVideoPreparer()
        )
        await vm.start()

        await vm.attachPhoto(data: Data("raw-photo".utf8), filename: "camera-1.jpg")
        #expect(preparedFilenames.withLock { $0 } == ["camera-1.jpg"])
        #expect(vm.pendingPhotos.count == 1)
        #expect(vm.pendingPhotos.first?.data == Data("clean-jpeg".utf8))

        let rawDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-camtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rawDir) }
        let rawVideo = rawDir.appendingPathComponent("camera-1.mov")
        try Data("raw-video-with-gps".utf8).write(to: rawVideo)

        await vm.attachVideo(fileURL: rawVideo, filename: "camera-1.mov", mimeType: "video/quicktime")
        #expect(vm.pendingVideos.count == 1)
        let stagedURL = try #require(vm.pendingVideos.first?.fileURL)
        #expect(FileManager.default.fileExists(atPath: stagedURL.path))
        #expect(stagedURL.deletingLastPathComponent().lastPathComponent.hasPrefix("halo-pending-video-clean-"))

        vm.removePendingVideos()
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
        await vm.stop()
    }

    @Test("CameraEntryButton and CameraStatusSheet lay out cleanly in Light, Dark, and AX5")
    func cameraViewsLightDarkAX5() throws {
        let configs: [(name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]
        let outDir = ProcessInfo.processInfo.environment["HALO_CAMERA_SNAPSHOT_DIR"]

        for config in configs {
            let content = VStack(spacing: 16) {
                CameraEntryButton(allowsVideo: true, isLoading: false, action: {})
                CameraStatusSheet(
                    status: .denied(canOpenSettings: true),
                    onOpenSettings: {},
                    onDismiss: {}
                )
                .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
                CameraStatusSheet(
                    status: .unavailable,
                    onOpenSettings: nil,
                    onDismiss: {}
                )
                .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
            }
            .padding(16)
            .frame(width: 390, alignment: .leading)
            .background(HaloColor.bgPrimary)
            .environment(\.dynamicTypeSize, config.size)
            .environment(\.colorScheme, config.style == .dark ? .dark : .light)

            let host = UIHostingController(rootView: content)
            host.overrideUserInterfaceStyle = config.style
            let fitted = host.sizeThatFits(in: CGSize(width: 390, height: 10_000))
            #expect(fitted.width >= 350 && fitted.height >= 300)

            if let outDir {
                let renderer = ImageRenderer(content: content.frame(width: fitted.width, height: fitted.height))
                renderer.scale = 2
                if let uiImage = renderer.uiImage, let png = uiImage.pngData() {
                    let url = URL(fileURLWithPath: outDir).appendingPathComponent("camera-ui-\(config.name).png")
                    try png.write(to: url)
                }
            }
        }
    }
}
#endif
