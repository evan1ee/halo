import Foundation

/// Device-level settings persisted in `UserDefaults` (docs/features/SETTINGS.md §7: `AppPreferences`). Every change is stored at once.
public struct AppPreferences: Sendable {
    /// `UserDefaults` is documented as thread-safe; the box only lets this struct be `Sendable`.
    private struct Box: @unchecked Sendable { let defaults: UserDefaults }
    private let box: Box

    public static let privateReceiptsKey = "halo.privateReadReceipts"
    public static let sendTypingNoticesKey = "halo.sendTypingNotices"
    public static let privacyBlurKey = "halo.privacyBlur"
    public static let appearanceKey = "halo.appearance"
    public static let botSendersKey = "halo.botSenders"

    public init(defaults: UserDefaults = .standard) { box = Box(defaults: defaults) }

    /// `true`: read receipts are sent as `m.read.private`, seen by nobody else (D7). Default `false`: public `m.read`.
    public var privateReceipts: Bool {
        get { box.defaults.bool(forKey: Self.privateReceiptsKey) }
        nonmutating set { box.defaults.set(newValue, forKey: Self.privateReceiptsKey) }
    }

    /// `true` (default): tell others in the room when the user is typing (SETTINGS §3). `false`: never send typing notices.
    public var sendTypingNotices: Bool {
        get { box.defaults.object(forKey: Self.sendTypingNoticesKey) as? Bool ?? true }
        nonmutating set { box.defaults.set(newValue, forKey: Self.sendTypingNoticesKey) }
    }

    /// `true` (default, D61): blur the app screen in the iOS app switcher while inactive or backgrounded (SECURITY §4).
    public var privacyBlur: Bool {
        get { box.defaults.object(forKey: Self.privacyBlurKey) as? Bool ?? true }
        nonmutating set { box.defaults.set(newValue, forKey: Self.privacyBlurKey) }
    }

    /// Local cache of user IDs whose recognised messages render as bot cards (Settings → Bots; synced via `one.mbm.halo.bot_allowlist`).
    public var botSenders: [String] {
        get { box.defaults.stringArray(forKey: Self.botSendersKey) ?? [] }
        nonmutating set { box.defaults.set(newValue, forKey: Self.botSendersKey) }
    }

    /// The colour scheme the user chose; `.system` follows the device. Unknown stored values read as `.system`.
    public var appearance: Appearance {
        get { Appearance(rawValue: box.defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system }
        nonmutating set { box.defaults.set(newValue.rawValue, forKey: Self.appearanceKey) }
    }
}

/// Settings → Appearance (docs/features/SETTINGS.md §2).
public enum Appearance: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
