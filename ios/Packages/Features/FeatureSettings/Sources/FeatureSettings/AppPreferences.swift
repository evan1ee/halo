import Foundation

/// Device-level settings persisted in `UserDefaults` (docs/features/SETTINGS.md §7: `AppPreferences`). Every change is stored at once.
public struct AppPreferences: Sendable {
    /// `UserDefaults` is documented as thread-safe; the box only lets this struct be `Sendable`.
    private struct Box: @unchecked Sendable { let defaults: UserDefaults }
    private let box: Box

    public static let privateReceiptsKey = "halo.privateReadReceipts"

    public init(defaults: UserDefaults = .standard) { box = Box(defaults: defaults) }

    /// `true`: read receipts are sent as `m.read.private`, seen by nobody else (D7). Default `false`: public `m.read`.
    public var privateReceipts: Bool {
        get { box.defaults.bool(forKey: Self.privateReceiptsKey) }
        nonmutating set { box.defaults.set(newValue, forKey: Self.privateReceiptsKey) }
    }
}
