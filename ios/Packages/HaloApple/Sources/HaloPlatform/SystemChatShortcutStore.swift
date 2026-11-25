import CoreSpotlight
import Foundation
import HaloDomain
import HaloFoundation
import UniformTypeIdentifiers

/// `ChatShortcutPort` over a JSON file in the App Group (read by the app's intents) and the Spotlight index (M16, D88).
/// Spotlight items carry the chat name only; a result opens the chat through `HaloSpotlight.roomID(from:)`.
public struct SystemChatShortcutStore: ChatShortcutPort {
    public static let domain = "one.mbm.halo.chat"

    private let file: URL
    /// `nil` skips the Spotlight index (tests).
    private let indexName: String?

    public init(file: URL, indexName: String? = "one.mbm.halo.chats") {
        self.file = file
        self.indexName = indexName
    }

    /// The default location: inside the App Group container, else Application Support.
    public static func defaultFile(bundle: Bundle = .main) -> URL {
        HaloShared.shareInboxDirectory(bundle: bundle).deletingLastPathComponent().appendingPathComponent("chat-shortcuts.json")
    }

    public func load() -> [ChatShortcut] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([ChatShortcut].self, from: data)) ?? []
    }

    public func replace(with shortcuts: [ChatShortcut]) async {
        write(shortcuts)
        guard let index else { return }
        // Replace the whole domain so a left or renamed chat doesn't linger in Spotlight.
        try? await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])  // best-effort: system index or badge; a miss is repaired by the next update
        let items = shortcuts.map { shortcut -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = shortcut.name
            attributes.displayName = shortcut.name
            return CSSearchableItem(uniqueIdentifier: shortcut.id, domainIdentifier: Self.domain, attributeSet: attributes)
        }
        try? await index.indexSearchableItems(items)  // best-effort: system index or badge; a miss is repaired by the next update
    }

    public func clear() async {
        write([])
        try? await index?.deleteSearchableItems(withDomainIdentifiers: [Self.domain])  // best-effort: system index or badge; a miss is repaired by the next update
    }

    private var index: CSSearchableIndex? { indexName.map { CSSearchableIndex(name: $0) } }

    private func write(_ shortcuts: [ChatShortcut]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if shortcuts.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONEncoder().encode(shortcuts) {
            try? data.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
        }
    }
}

/// Reads a Spotlight result's activity.
public enum HaloSpotlight {
    /// The room a `CSSearchableItemActionType` activity points at: the item's identifier, when it is a valid room ID.
    public static func roomID(fromIdentifier identifier: String?) -> RoomID? {
        identifier.flatMap { try? RoomID($0) }
    }
}
