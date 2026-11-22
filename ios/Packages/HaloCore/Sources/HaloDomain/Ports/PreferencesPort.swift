import Foundation

/// Device-level appearance choice (`docs/features/SETTINGS.md` §2).
public enum AppAppearance: String, CaseIterable, Sendable, Codable, Equatable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// Device-level user preferences persisted outside Matrix sync state (TD-02, SETTINGS §7).
public struct PreferencesSnapshot: Sendable, Equatable, Codable {
    /// `true`: send read receipts as `m.read.private` (D7). Default `false` (public `m.read`).
    public var privateReceipts: Bool
    /// `true` (default): send outgoing typing notices.
    public var sendTypingNotices: Bool
    /// `true` (default, D61): hide screen content in app switcher when inactive.
    public var privacyBlur: Bool
    /// Local cache of allowlisted bot user IDs (`one.mbm.halo.bot_allowlist`).
    public var botSenders: [String]
    /// System / Light / Dark theme preference.
    public var appearance: AppAppearance
    /// Last marketing version (`CFBundleShortVersionString`) for which What's New was shown (M15).
    public var lastSeenWhatsNewVersion: String?
    /// `true`: joined chat names are offered to Siri, Shortcuts and Spotlight (M16, D88). Default `false`: opt-in, names leave the app.
    public var chatsInSystemSearch: Bool

    public init(
        privateReceipts: Bool = false,
        sendTypingNotices: Bool = true,
        privacyBlur: Bool = true,
        botSenders: [String] = [],
        appearance: AppAppearance = .system,
        lastSeenWhatsNewVersion: String? = nil,
        chatsInSystemSearch: Bool = false
    ) {
        self.privateReceipts = privateReceipts
        self.sendTypingNotices = sendTypingNotices
        self.privacyBlur = privacyBlur
        self.botSenders = botSenders
        self.appearance = appearance
        self.lastSeenWhatsNewVersion = lastSeenWhatsNewVersion
        self.chatsInSystemSearch = chatsInSystemSearch
    }
}

/// Port for reading and persisting device-level preferences (TD-02, ADR-0022).
/// Implemented by `HaloPlatform.UserDefaultsPreferencesStore`; faked in `HaloTestSupport`.
public protocol PreferencesPort: Sendable {
    func load() -> PreferencesSnapshot
    func save(_ snapshot: PreferencesSnapshot)
}
