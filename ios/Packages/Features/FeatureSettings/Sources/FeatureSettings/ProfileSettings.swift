import Foundation
import Observation

/// What the profile settings screen needs from the app (USER_PROFILES FR-1, FR-4); closures keep this package free of the domain.
public struct ProfileSettingsActions: Sendable {
    public let loadName: @Sendable () async -> String?
    public let saveName: @Sendable (String) async -> Bool
    public let loadIgnored: @Sendable () async -> [String]?
    public let unignore: @Sendable (String) async -> Bool
    /// The avatar's image bytes; `nil` when there is none.
    public let loadAvatar: @Sendable () async -> Data?
    /// Shrinks and uploads a picked photo; `false` when it isn't an image or the upload failed.
    public let setAvatar: @Sendable (Data) async -> Bool
    public let removeAvatar: @Sendable () async -> Bool

    public init(
        loadName: @escaping @Sendable () async -> String?, saveName: @escaping @Sendable (String) async -> Bool,
        loadIgnored: @escaping @Sendable () async -> [String]?, unignore: @escaping @Sendable (String) async -> Bool,
        loadAvatar: @escaping @Sendable () async -> Data? = { nil }, setAvatar: @escaping @Sendable (Data) async -> Bool = { _ in false },
        removeAvatar: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.loadAvatar = loadAvatar
        self.setAvatar = setAvatar
        self.removeAvatar = removeAvatar
        self.loadName = loadName
        self.saveName = saveName
        self.loadIgnored = loadIgnored
        self.unignore = unignore
    }
}

/// Own display name and the ignored users list.
@MainActor @Observable
public final class ProfileSettingsModel {
    public var name = ""
    public private(set) var savedName = ""
    public private(set) var ignored: [String] = []
    public private(set) var isLoaded = false
    /// The current avatar image; `nil` shows a placeholder.
    public private(set) var avatar: Data?
    public private(set) var message: String?

    private let actions: ProfileSettingsActions

    public init(actions: ProfileSettingsActions) { self.actions = actions }

    public func load() async {
        guard let current = await actions.loadName() else { message = "Your profile couldn't be loaded."; return }
        name = current
        savedName = current
        ignored = await actions.loadIgnored() ?? []
        avatar = await actions.loadAvatar()
        isLoaded = true
        message = nil
    }

    public var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return isLoaded && !trimmed.isEmpty && trimmed != savedName
    }

    public func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave else { return }
        if await actions.saveName(trimmed) {
            savedName = trimmed
            name = trimmed
            message = "Saved."
        } else { message = "That couldn't be saved. Check your connection and try again." }
    }

    /// A photo the user picked (already read into memory).
    public func choosePhoto(_ data: Data) async {
        if await actions.setAvatar(data) {
            avatar = await actions.loadAvatar()
            message = "Photo updated."
        } else { message = "That photo couldn't be used. Try another one." }
    }

    public func removePhoto() async {
        if await actions.removeAvatar() {
            avatar = nil
            message = "Photo removed."
        } else { message = "That couldn't be removed. Try again." }
    }

    public func unignore(_ user: String) async {
        if await actions.unignore(user) {
            ignored.removeAll { $0 == user }
            message = nil
        } else { message = "That didn't work. Try again." }
    }
}
