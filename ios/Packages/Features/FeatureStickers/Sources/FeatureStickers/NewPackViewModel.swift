import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// The "new sticker pack" screen: a name, photos, an editable shortcode per photo, then create (STICKERS FR-7).
@MainActor @Observable
public final class NewPackViewModel: Identifiable {
    public struct Item: Identifiable, Equatable {
        public let id = UUID()
        public let data: Data
        public let filename: String
        public var shortcode: String
    }

    public enum Phase: Equatable { case editing, uploading(done: Int, total: Int), done, failed(String) }

    public var name = ""
    public private(set) var items: [Item] = []
    public private(set) var phase = Phase.editing

    private let creator: StickerPackCreator
    private let onCreated: @MainActor () async -> Void

    /// - Parameter onCreated: called after the pack exists, so the panel can reload.
    public init(creator: StickerPackCreator, onCreated: @escaping @MainActor () async -> Void = {}) {
        self.creator = creator
        self.onCreated = onCreated
    }

    /// Adds a picked photo with a shortcode from its file name.
    public func add(data: Data, filename: String) {
        guard items.count < ImagePackBuilder.maximumImages else { return }
        let code = StickerPackCreator.shortcode(forFilename: filename, avoiding: Set(items.map(\.shortcode)))
        items.append(Item(data: data, filename: filename, shortcode: code))
    }

    public func remove(_ item: Item) { items.removeAll { $0.id == item.id } }

    public func setShortcode(_ shortcode: String, for item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].shortcode = shortcode
    }

    /// Why the shortcode of `item` can't be used, or `nil` if it is fine.
    public func problem(with item: Item) -> String? {
        if !ShortcodeRules.isValid(item.shortcode) { return "Use letters, digits, - and _ (up to 100)." }
        if items.contains(where: { $0.id != item.id && $0.shortcode == item.shortcode }) { return "Another sticker has this name." }
        return nil
    }

    public var canCreate: Bool {
        guard case .editing = phase else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !items.isEmpty && items.allSatisfy { problem(with: $0) == nil }
    }

    public var isBusy: Bool { if case .uploading = phase { true } else { false } }

    public func create() async {
        guard canCreate else { return }
        phase = .uploading(done: 0, total: items.count)
        let pictures = items.map { StickerPackCreator.Picked(data: $0.data, filename: $0.filename, shortcode: $0.shortcode) }
        let total = items.count
        do {
            _ = try await creator.create(name: name, pictures: pictures) { [weak self] done, _ in
                Task { @MainActor in if let self, case .uploading = self.phase { self.phase = .uploading(done: done, total: total) } }
            }
            phase = .done
            await onCreated()
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Back to editing after a failure; the photos and names are kept.
    public func dismissError() { if case .failed = phase { phase = .editing } }

    static func message(for error: HaloError) -> String {
        switch error {
        case .invalidInput("NOT_AN_IMAGE"): "One of the files isn't a picture."
        case .invalidInput("IMAGE_TOO_LARGE"): "One of the pictures is too large (5 MB at most after shrinking)."
        case .network(retryable: true): "Can't reach the server. Nothing was created; try again."
        case .forbidden: "The server doesn't allow creating rooms."
        default: "The pack couldn't be created."
        }
    }
}
