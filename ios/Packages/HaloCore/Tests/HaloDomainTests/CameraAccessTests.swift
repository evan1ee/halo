import HaloDomain
import Testing

@Suite("CameraAccessPolicy (M20-5)")
struct CameraAccessTests {
    @Test("unavailable hardware always returns showUnavailable regardless of permission status")
    func unavailableCamera() {
        for status: CameraAuthorizationStatus in [.notDetermined, .authorized, .denied, .restricted] {
            #expect(CameraAccessPolicy.decide(isCameraAvailable: false, status: status) == .showUnavailable)
        }
    }

    @Test("available hardware maps each authorization status cleanly")
    func availableCameraDecisions() {
        #expect(CameraAccessPolicy.decide(isCameraAvailable: true, status: .authorized) == .openCamera)
        #expect(CameraAccessPolicy.decide(isCameraAvailable: true, status: .notDetermined) == .requestPermission)
        #expect(CameraAccessPolicy.decide(isCameraAvailable: true, status: .denied) == .showDenied(canOpenSettings: true))
        #expect(CameraAccessPolicy.decide(isCameraAvailable: true, status: .restricted) == .showDenied(canOpenSettings: false))
    }

    @Test("short video capture cap is positive and reasonable")
    func captureLimits() {
        #expect(CameraCaptureLimits.maximumVideoDuration == 60)
    }
}
