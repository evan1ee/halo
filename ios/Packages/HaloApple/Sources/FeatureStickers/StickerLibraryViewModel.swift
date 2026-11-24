import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// Drives the full Sticker Pack Manager (`StickerLibraryView` and `StickerPackDetailView`):
/// visual pack browsing, creating packs, renaming, adding stickers, deleting single stickers, and deleting whole packs.
@MainActor @Observable
public final class StickerLibraryViewModel {
    public private(set) var packs: [StickerPack] = []
    public private(set) var unavailableCount = 0
    public private(set) var isLoading = false
    public private(set) var isBusy = false
    public private(set) var uploadProgress: (done: Int, total: Int)?
    public private(set) var error: String?

    private let library: StickerLibrary
    private let manager: StickerPackManager
    private let media: MediaLoader?
    private let makeNewPack: (@MainActor (@escaping @MainActor () async -> Void) -> NewPackViewModel)?
    private var observer: Task<Void, Never>?

    public init(
        library: StickerLibrary,
        manager: StickerPackManager,
        media: MediaLoader? = nil,
        newPack: (@MainActor (@escaping @MainActor () async -> Void) -> NewPackViewModel)? = nil
    ) {
        self.library = library
        self.manager = manager
        self.media = media
        self.makeNewPack = newPack
    }

    public var canCreatePack: Bool { makeNewPack != nil }

    public func pack(for ref: PackRef) -> StickerPack? {
        packs.first { $0.ref == ref }
    }

    public func start() async {
        observer?.cancel()
        let stream = await library.snapshots()
        observer = Task { [weak self] in
            for await snapshot in stream {
                self?.apply(snapshot)
            }
        }
        await library.load(currentRoom: nil)
        await syncCurrentSnapshot()
    }

    public func stop() {
        observer?.cancel()
        observer = nil
    }

    public func reload() async {
        await library.load(currentRoom: nil)
        await syncCurrentSnapshot()
    }

    public func beginNewPack() -> NewPackViewModel? {
        makeNewPack? { [weak self] in
            await self?.library.load(currentRoom: nil)
        }
    }

    public func dismissError() { error = nil }

    @discardableResult
    public func rename(_ ref: PackRef, to name: String) async -> Bool {
        error = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await manager.rename(ref, to: name)
            await syncCurrentSnapshot()
            return true
        } catch {
            self.error = Self.message(for: error, fallback: "The pack couldn't be renamed.")
            return false
        }
    }

    @discardableResult
    public func addStickers(to ref: PackRef, files: [(data: Data, filename: String)]) async -> Bool {
        guard !files.isEmpty else { return false }
        error = nil
        isBusy = true
        uploadProgress = (0, files.count)
        defer {
            isBusy = false
            uploadProgress = nil
        }

        let existing = Set((pack(for: ref)?.stickers ?? []).map(\.shortcode))
        var taken = existing
        var picked: [StickerPackCreator.Picked] = []
        for file in files {
            let code = StickerPackCreator.shortcode(forFilename: file.filename, avoiding: taken)
            taken.insert(code)
            picked.append(StickerPackCreator.Picked(data: file.data, filename: file.filename, shortcode: code))
        }

        let total = picked.count
        do {
            try await manager.addStickers(to: ref, existingShortcodes: existing, pictures: picked) { [weak self] done, _ in
                Task { @MainActor in
                    self?.uploadProgress = (done, total)
                }
            }
            await syncCurrentSnapshot()
            return true
        } catch {
            self.error = Self.message(for: error, fallback: "The stickers couldn't be added.")
            return false
        }
    }

    @discardableResult
    public func removeSticker(shortcode: String, from ref: PackRef) async -> Bool {
        error = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await manager.removeSticker(shortcode: shortcode, from: ref)
            await syncCurrentSnapshot()
            return true
        } catch {
            self.error = Self.message(for: error, fallback: "The sticker couldn't be deleted.")
            return false
        }
    }

    @discardableResult
    public func deletePack(_ ref: PackRef) async -> Bool {
        error = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await manager.deletePack(ref)
            await syncCurrentSnapshot()
            return true
        } catch {
            self.error = Self.message(for: error, fallback: "The pack couldn't be deleted.")
            return false
        }
    }

    public func removeUnavailablePacks() async {
        await library.removeUnavailablePacks()
    }

    public func thumbnail(for sticker: Sticker) async -> Data? {
        guard let media, let ref = sticker.image else { return nil }
        return try? await media.thumbnail(ref, width: 160, height: 160)
    }

    public func fullImage(for sticker: Sticker) async -> Data? {
        guard let media, let ref = sticker.image else { return nil }
        return try? await media.content(ref)
    }

    private func syncCurrentSnapshot() async {
        let stream = await library.snapshots()
        for await latest in stream {
            apply(latest)
            break
        }
    }

    private func apply(_ snapshot: StickerLibrary.Snapshot) {
        packs = snapshot.packs.filter { $0.source == .userEnabled }
        unavailableCount = snapshot.unavailablePacks.count
        isLoading = snapshot.phase == .loading && packs.isEmpty
    }

    static func message(for error: HaloError, fallback: String) -> String {
        switch error {
        case .invalidInput("EMPTY_PACK_NAME"): "Enter a pack name."
        case .invalidInput("NOT_AN_IMAGE"): "One of the selected files isn't an image."
        case .invalidInput("IMAGE_TOO_LARGE"): "One of the images is too large (5 MB max after resizing)."
        case .invalidInput("TOO_MANY_IMAGES"): "A pack can hold at most \(ImagePackBuilder.maximumImages) stickers."
        case .forbidden: "You don't have permission to edit this pack."
        case .network(retryable: true): "Can't reach the server. Check your connection and try again."
        default: fallback
        }
    }
}
