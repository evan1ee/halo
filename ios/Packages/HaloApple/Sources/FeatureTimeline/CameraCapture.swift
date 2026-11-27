#if canImport(UIKit)
import AVFoundation
import HaloDesignSystem
import HaloDomain
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Media returned by the in-composer system camera (MEDIA_ATTACHMENTS FR-9, M20-5).
public enum CameraCaptureResult: Sendable {
    case photo(data: Data, filename: String)
    /// Temporary video file copied out of `UIImagePickerController`'s ephemeral directory. Caller deletes its parent folder once staged.
    case video(fileURL: URL, filename: String, mimeType: String)
}

/// Real `CameraAuthorizing` backed by `UIImagePickerController` and `AVCaptureDevice`.
public struct SystemCameraAuthorizer: CameraAuthorizing {
    public init() {}

    public var isCameraAvailable: Bool {
        MainActor.assumeIsolated {
            UIImagePickerController.isSourceTypeAvailable(.camera)
        }
    }

    public func authorizationStatus() -> CameraAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    public func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

/// Coordinates in-context camera permission requests and sheet presentation (MEDIA_ATTACHMENTS FR-9, M20-5).
///
/// Never requests camera access eagerly: permission is requested only when `openCamera()` is invoked from a tap.
@MainActor @Observable
public final class CameraPermissionController {
    public enum StatusSheet: Equatable, Identifiable {
        case denied(canOpenSettings: Bool)
        case unavailable
        case captureError(String)

        public var id: String {
            switch self {
            case .denied(let canOpen): "denied-\(canOpen)"
            case .unavailable: "unavailable"
            case .captureError(let message): "error-\(message)"
            }
        }
    }

    public private(set) var isPresentingCamera = false
    public private(set) var statusSheet: StatusSheet?
    public private(set) var isRequestingPermission = false

    @ObservationIgnored private let authorizer: any CameraAuthorizing

    public init(authorizer: any CameraAuthorizing = SystemCameraAuthorizer()) {
        self.authorizer = authorizer
    }

    /// Evaluates camera availability and authorization in context, prompting the user only when `.notDetermined`.
    public func openCamera() async {
        guard !isRequestingPermission else { return }
        switch CameraAccessPolicy.decide(
            isCameraAvailable: authorizer.isCameraAvailable,
            status: authorizer.authorizationStatus()
        ) {
        case .openCamera:
            statusSheet = nil
            isPresentingCamera = true
        case .requestPermission:
            isRequestingPermission = true
            let granted = await authorizer.requestAccess()
            isRequestingPermission = false
            if granted {
                statusSheet = nil
                isPresentingCamera = true
            } else {
                statusSheet = .denied(canOpenSettings: true)
            }
        case .showDenied(let canOpenSettings):
            statusSheet = .denied(canOpenSettings: canOpenSettings)
        case .showUnavailable:
            statusSheet = .unavailable
        }
    }

    public func dismissCamera() {
        isPresentingCamera = false
    }

    public func dismissStatusSheet() {
        statusSheet = nil
    }

    public func reportCaptureError(_ message: String) {
        isPresentingCamera = false
        statusSheet = .captureError(message)
    }
}

/// Prominent, accessible camera entry button placed at the top of the Gallery attachment tab (M20-5).
struct CameraEntryButton: View {
    let allowsVideo: Bool
    let isLoading: Bool
    let action: () -> Void

    private var title: String {
        allowsVideo ? "Take photo or video" : "Take photo"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HaloSpacing.s) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "camera.fill")
                        .font(HaloTypography.bodyEmphasis)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .foregroundStyle(HaloColor.accent)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(HaloTypography.bodyEmphasis)
                    .foregroundStyle(HaloColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: HaloSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(HaloTypography.captionEmphasis)
                    .foregroundStyle(HaloColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, HaloSpacing.m)
            .padding(.vertical, HaloSpacing.s)
            .frame(minHeight: 44)
            .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(title)
        .accessibilityHint("Opens the camera to capture media for this chat")
        .accessibilityIdentifier("camera-button")
    }
}

/// Clear, honest Apple-native sheet shown when camera permission is denied, restricted, unavailable, or capture failed (M20-5).
struct CameraStatusSheet: View {
    let status: CameraPermissionController.StatusSheet
    let onOpenSettings: (() -> Void)?
    let onDismiss: () -> Void

    private var symbol: String {
        switch status {
        case .denied: "camera.badge.ellipsis"
        case .unavailable: "camera.fill"
        case .captureError: "exclamationmark.triangle.fill"
        }
    }

    private var heading: String {
        switch status {
        case .denied: "Camera access is off"
        case .unavailable: "Camera isn't available"
        case .captureError: "Couldn't use camera"
        }
    }

    private var message: String {
        switch status {
        case .denied(canOpenSettings: true):
            "To take photos and videos, allow Halo to use the camera in Settings."
        case .denied(canOpenSettings: false):
            "Camera access is restricted on this device and can't be enabled here."
        case .unavailable:
            "This device doesn't have an available camera right now."
        case .captureError(let detail):
            detail
        }
    }

    private var showsSettingsButton: Bool {
        if case .denied(canOpenSettings: true) = status, onOpenSettings != nil {
            return true
        }
        return false
    }

    var body: some View {
        VStack(spacing: HaloSpacing.l) {
            Image(systemName: symbol)
                .font(HaloTypography.title)
                .imageScale(.large)
                .foregroundStyle(HaloColor.accent)
                .accessibilityHidden(true)
            VStack(spacing: HaloSpacing.xs) {
                Text(heading)
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, HaloSpacing.m)

            VStack(spacing: HaloSpacing.s) {
                if showsSettingsButton, let onOpenSettings {
                    Button {
                        onOpenSettings()
                        onDismiss()
                    } label: {
                        Text("Open Settings")
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("camera-open-settings")
                }
                Button(role: .cancel) {
                    onDismiss()
                } label: {
                    Text(showsSettingsButton ? "Not now" : "OK")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("camera-status-dismiss")
            }
        }
        .padding(HaloSpacing.l)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("camera-status-sheet")
    }
}

/// Native `UIImagePickerController` camera wrapper for capturing photos and short videos (MEDIA_ATTACHMENTS FR-9, M20-5).
struct CameraPickerSheet: UIViewControllerRepresentable {
    let allowsVideo: Bool
    let onCapture: (CameraCaptureResult) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onError: onError, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = allowsVideo
            ? [UTType.image.identifier, UTType.movie.identifier]
            : [UTType.image.identifier]
        picker.videoMaximumDuration = CameraCaptureLimits.maximumVideoDuration
        picker.videoQuality = .typeMedium
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (CameraCaptureResult) -> Void
        private let onError: (String) -> Void
        private let onCancel: () -> Void

        init(
            onCapture: @escaping (CameraCaptureResult) -> Void,
            onError: @escaping (String) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onCapture = onCapture
            self.onError = onError
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let mediaType = info[.mediaType] as? String
            if mediaType == UTType.movie.identifier, let sourceURL = info[.mediaURL] as? URL {
                // UIImagePickerController cleans up its temporary recording right after the delegate returns,
                // so copy immediately into our own temporary folder before handing off.
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("halo-camera-video-\(UUID().uuidString)", isDirectory: true)
                let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension.lowercased()
                let filename = "camera-\(Int(Date().timeIntervalSince1970)).\(ext)"
                let destURL = dir.appendingPathComponent(filename)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                    let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/quicktime"
                    onCapture(.video(fileURL: destURL, filename: filename, mimeType: mime))
                } catch {
                    try? FileManager.default.removeItem(at: dir)
                    onError("Couldn't save the recorded video.")
                }
                return
            }

            if let image = info[.originalImage] as? UIImage,
               let jpeg = image.jpegData(compressionQuality: 0.92) {
                let filename = "camera-\(Int(Date().timeIntervalSince1970)).jpg"
                onCapture(.photo(data: jpeg, filename: filename))
                return
            }

            onError("Couldn't read the captured photo.")
        }
    }
}
#endif
