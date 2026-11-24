import Foundation
import HaloDomain
import HaloFoundation

/// Manages existing sticker packs: rename, add stickers, delete a single sticker, or delete a whole pack.
/// Reloads `StickerLibrary` after each successful mutation so the library and composer panel stay in sync.
public actor StickerPackManager {
    private let port: any StickerPackManagementPort
    private let preparer: any ImagePreparing
    private let library: StickerLibrary

    public init(port: any StickerPackManagementPort, preparer: any ImagePreparing, library: StickerLibrary) {
        self.port = port
        self.preparer = preparer
        self.library = library
    }

    public func rename(_ ref: PackRef, to name: String) async throws(HaloError) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .invalidInput("EMPTY_PACK_NAME") }
        try await port.renamePack(ref, to: trimmed)
        await library.reload()
    }

    /// Prepares `pictures` (512 px max, ≤ 5 MB) and adds them to `ref`.
    public func addStickers(
        to ref: PackRef,
        existingShortcodes: Set<String>,
        pictures: [StickerPackCreator.Picked],
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws(HaloError) {
        guard !pictures.isEmpty else { throw .invalidInput("NO_IMAGES") }
        guard existingShortcodes.count + pictures.count <= ImagePackBuilder.maximumImages else {
            throw .invalidInput("TOO_MANY_IMAGES")
        }
        var seen = existingShortcodes
        var preparedImages: [NewStickerImage] = []
        for picture in pictures {
            guard ShortcodeRules.isValid(picture.shortcode) else { throw .invalidInput("BAD_SHORTCODE") }
            guard seen.insert(picture.shortcode).inserted else { throw .invalidInput("DUPLICATE_SHORTCODE") }
            let prepared = try preparer.prepare(data: picture.data, filename: picture.filename)
            guard prepared.data.count <= StickerPackCreator.maximumImageBytes else { throw .invalidInput("IMAGE_TOO_LARGE") }
            preparedImages.append(NewStickerImage(
                data: prepared.data, mimeType: prepared.mimeType, width: prepared.width, height: prepared.height,
                shortcode: picture.shortcode
            ))
        }
        try await port.addStickers(preparedImages, to: ref, progress: progress)
        await library.reload()
    }

    public func removeSticker(shortcode: String, from ref: PackRef) async throws(HaloError) {
        try await port.removeSticker(shortcode: shortcode, from: ref)
        await library.reload()
    }

    public func deletePack(_ ref: PackRef) async throws(HaloError) {
        try await port.deletePack(ref)
        await library.reload()
    }
}
