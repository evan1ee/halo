import Foundation

/// Current system camera permission status, decoupled from `AVFoundation` so `HaloDomain` stays pure Swift (M20-5).
public enum CameraAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// Action the composer takes when the user taps Camera (MEDIA_ATTACHMENTS FR-9, M20-5).
public enum CameraAccessDecision: Sendable, Equatable {
    case openCamera
    case requestPermission
    case showDenied(canOpenSettings: Bool)
    case showUnavailable
}

/// Pure policy for camera permission requests: never ask eagerly, always ask in context, and show an honest denied/unavailable state.
public enum CameraAccessPolicy {
    public static func decide(
        isCameraAvailable: Bool,
        status: CameraAuthorizationStatus
    ) -> CameraAccessDecision {
        guard isCameraAvailable else { return .showUnavailable }
        return switch status {
        case .authorized: .openCamera
        case .notDetermined: .requestPermission
        case .denied: .showDenied(canOpenSettings: true)
        case .restricted: .showDenied(canOpenSettings: false)
        }
    }
}

/// Limits for in-composer camera captures (MEDIA_ATTACHMENTS FR-9, M20-5).
public enum CameraCaptureLimits {
    /// Short videos captured from the composer cap at 60 seconds so uploads stay comfortably under `OutgoingFile.maximumBytes`.
    public static let maximumVideoDuration: TimeInterval = 60
}

/// Abstraction over hardware availability and camera permission queries, allowing deterministic tests without camera hardware.
public protocol CameraAuthorizing: Sendable {
    var isCameraAvailable: Bool { get }
    func authorizationStatus() -> CameraAuthorizationStatus
    func requestAccess() async -> Bool
}
