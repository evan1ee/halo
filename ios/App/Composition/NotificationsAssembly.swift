import Foundation
import UserNotifications

/// Push gateway configuration and iOS notification permission status (ADR-0022 step 2).
extension AppRoot {
    static func pushConfiguration() -> (appID: String, gateway: URL)? {
        guard let appID = Bundle.main.object(forInfoDictionaryKey: "HaloPushAppID") as? String, !appID.isEmpty,
              let raw = Bundle.main.object(forInfoDictionaryKey: "HaloPushGatewayURL") as? String, !raw.isEmpty,
              let gateway = URL(string: raw) else { return nil }
        return (appID, gateway)
    }

    nonisolated func notificationStatus() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off in iOS Settings"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }
}
