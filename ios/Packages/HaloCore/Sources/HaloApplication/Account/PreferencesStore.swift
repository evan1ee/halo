import HaloDomain
import Observation

/// Observable store over `PreferencesPort` (TD-02, ADR-0022).
///
/// Replaces ad-hoc `AppPreferences()` reads in the app composition root so changes (such as bot allowlist,
/// appearance, privacy blur, or receipt privacy) propagate live across the UI without relaunch.
@MainActor @Observable
public final class PreferencesStore {
    private let port: any PreferencesPort
    public private(set) var snapshot: PreferencesSnapshot

    public init(port: any PreferencesPort) {
        self.port = port
        self.snapshot = port.load()
    }

    public var privateReceipts: Bool {
        get { snapshot.privateReceipts }
        set { update { $0.privateReceipts = newValue } }
    }

    public var sendTypingNotices: Bool {
        get { snapshot.sendTypingNotices }
        set { update { $0.sendTypingNotices = newValue } }
    }

    public var privacyBlur: Bool {
        get { snapshot.privacyBlur }
        set { update { $0.privacyBlur = newValue } }
    }

    public var botSenders: [String] {
        get { snapshot.botSenders }
        set { update { $0.botSenders = newValue } }
    }

    public var appearance: AppAppearance {
        get { snapshot.appearance }
        set { update { $0.appearance = newValue } }
    }

    public var lastSeenWhatsNewVersion: String? {
        get { snapshot.lastSeenWhatsNewVersion }
        set { update { $0.lastSeenWhatsNewVersion = newValue } }
    }

    /// Reloads from the backing port (e.g. if another view wrote via legacy `UserDefaults`).
    public func reload() {
        snapshot = port.load()
    }

    private func update(_ mutate: (inout PreferencesSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        snapshot = next
        port.save(next)
    }
}
