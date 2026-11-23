import Foundation
import HaloApplication
import HaloBotRendering
import HaloDomain
import HaloFoundation
import Observation

extension TimelineViewModel {
    // MARK: Opening files

    /// A downloaded copy of an attachment, in a temporary folder, shown in Quick Look.
    public struct OpenedFile: Identifiable, Equatable {
        public let id = UUID()
        public let url: URL
    }

    /// The id of the row whose file is downloading.
    /// Files are read into memory whole for now (`MediaPort.content`); bigger ones wait for a file-based download.
    public nonisolated static let openSizeLimit = 50 * 1024 * 1024

    public func openFile(_ row: TimelineRow) async {
        guard let file = row.file, media != nil, openingRow == nil else { return }
        openFileError = nil
        if let size = file.size, size > Self.openSizeLimit {
            openFileError = "This file is too large to open here yet (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            return
        }
        openingRow = row.id
        defer { openingRow = nil }
        do {
            let url = try await downloadFileToTemp(file)
            openedFile = OpenedFile(url: url)
        } catch {
            openFileError = (error as? HaloError) == .network(retryable: true) ? "Can't reach the server. The file wasn't opened." : "The file couldn't be opened."
        }
    }

    /// Downloads a file attachment into a sanitized temporary directory (used by Quick Look and drag-out).
    public func downloadFileToTemp(_ file: TimelineRow.FileTile) async throws -> URL {
        guard let media else { throw HaloError.notFound }
        if let size = file.size, size > Self.openSizeLimit {
            throw HaloError.invalidInput("File exceeds the 50 MB size limit")
        }
        let data = try await media.content(file.ref)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The name comes from the sender: keep only its last path component so it can't leave the folder.
        let last = URL(fileURLWithPath: file.name).lastPathComponent
        let url = directory.appendingPathComponent(last.isEmpty || last == "." || last == ".." ? "file" : last)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Quick Look was dismissed: the temporary copy is deleted.
    public func closeFile() {
        if let url = openedFile?.url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        openedFile = nil
    }

    public func dismissOpenFileError() { openFileError = nil }

    public func loadEarlier() async { await coordinator.paginateBackwards() }

    // MARK: Edit history (TIMELINE FR-9)

    public struct EditVersion: Equatable, Identifiable, Sendable {
        public let id: Int
        public let text: String
        public let time: String?
        public let isCurrent: Bool
    }

    public enum EditHistoryState: Equatable, Sendable {
        case loading
        /// Newest first.
        case loaded([EditVersion])
        case failed(String)
    }

    /// The edit history sheet; `nil` while closed.

    /// Opens the history of an edited message: every version with the time of the edit, newest first.
    public func showEditHistory(_ row: TimelineRow) async {
        guard row.isEdited, let id = row.eventID else { return }
        editHistory = .loading
        do {
            let revisions = try await coordinator.editHistory(of: id)
            guard editHistory == .loading else { return }  // closed meanwhile
            let versions = revisions.enumerated().map { index, revision in
                EditVersion(
                    id: index, text: revision.text, time: revision.timestamp.map { editTimeFormatter.string(from: $0) },
                    isCurrent: index == revisions.count - 1)
            }
            editHistory = .loaded(versions.reversed())
        } catch {
            guard editHistory == .loading else { return }
            editHistory = .failed(error == .network(retryable: true) ? "Can't reach the server." : "The edit history isn't available.")
        }
    }

    public func closeEditHistory() { editHistory = nil }

    /// Sends the draft (MESSAGING FR-2). The message shows up in the timeline as a local echo.
    public func send() async {
        guard canSend else { return }
        if !pendingPhotos.isEmpty { await sendPendingPhotos(); return }
        let text = draft
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            if let editing {
                try await coordinator.edit(event: editing, newText: text)
                self.editing = nil
                draft = stashedDraft
                stashedDraft = ""
                return
            } else if let id = replyingTo?.eventID {
                try await coordinator.reply(to: id, text: text, mentions: pendingMentions)
                replyingTo = nil
            } else {
                try await coordinator.send(text, mentions: pendingMentions)
            }
            pendingMentions = []
            draft = ""
        } catch {
            sendError = error == .network(retryable: true) ? "Can't reach the server. Your message was kept." : "The message couldn't be sent."
        }
    }

    /// `true` when the composer can attach photos.
    public var canSendImages: Bool { imagePreparer != nil }
    /// A photo is being prepared or uploaded.

    /// Maximum number of photos that can be attached together in one batch.
    public static let maxPendingPhotos = 10

    /// Photos picked and prepared but not sent yet; the composer text becomes the first photo's caption when sent.

    /// The first pending photo, or `nil` when none are attached.
    public var pendingPhoto: OutgoingImage? { pendingPhotos.first }

    /// Prepares a picked photo and appends it to the composer's pending photos (up to `maxPendingPhotos`).
    public func attachPhoto(data: Data, filename: String) async {
        await attachPhotos([(data: data, filename: filename)])
    }

    /// Prepares multiple picked photos sequentially off the main actor and appends valid ones to `pendingPhotos`.
    public func attachPhotos(_ items: [(data: Data, filename: String)]) async {
        guard let imagePreparer, !isSendingImage, !items.isEmpty else { return }
        isSendingImage = true
        sendError = nil
        defer { isSendingImage = false }
        var lastError: HaloError?
        for item in items {
            guard pendingPhotos.count < Self.maxPendingPhotos else { break }
            do {
                let prepared = try await Self.prepare(imagePreparer, item.data, item.filename)
                pendingPhotos.append(prepared)
            } catch {
                lastError = error
            }
        }
        if let error = lastError {
            sendError = error == .invalidInput("NOT_AN_IMAGE")
                ? "That file isn't a picture."
                : error == .invalidInput("IMAGE_TOO_LARGE")
                    ? "That picture is too large to send."
                    : "That picture couldn't be read."
        }
    }

    /// Drops one pending photo at `index`; the typed text and other photos stay.
    public func removePendingPhoto(at index: Int) {
        guard pendingPhotos.indices.contains(index) else { return }
        pendingPhotos.remove(at: index)
    }

    /// Drops all held photos; the typed text stays.
    public func removePendingPhoto() { pendingPhotos.removeAll() }

    /// Sends all held photos in order, attaching the composer text as the first photo's caption.
    /// Removes each photo as it succeeds so a mid-batch failure keeps only the unsent photos.
    func sendPendingPhotos() async {
        isSendingImage = true
        sendError = nil
        defer { isSendingImage = false }
        var caption: String? = {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        while let photo = pendingPhotos.first {
            let outgoing = OutgoingImage(
                data: photo.data, filename: photo.filename, mimeType: photo.mimeType,
                width: photo.width, height: photo.height, caption: caption)
            do {
                try await coordinator.sendImage(outgoing)
                pendingPhotos.removeFirst()
                if caption != nil {
                    caption = nil
                    draft = ""
                }
            } catch {
                sendError = error == .network(retryable: true)
                    ? "Can't reach the server. The picture wasn't sent."
                    : "The picture couldn't be sent."
                return
            }
        }
    }

    /// Sends a picked photo: shrinks it, strips its metadata, uploads it. The message shows as a local echo while uploading.
    public func sendImage(data: Data, filename: String) async {
        guard let imagePreparer, !isSendingImage else { return }
        isSendingImage = true
        sendError = nil
        defer { isSendingImage = false }
        do {
            let image = try await Self.prepare(imagePreparer, data, filename)
            try await coordinator.sendImage(image)
        } catch {
            switch error {
            case .invalidInput("NOT_AN_IMAGE"): sendError = "That file isn't a picture."
            case .invalidInput("IMAGE_TOO_LARGE"): sendError = "That picture is too large to send."
            case .network(retryable: true): sendError = "Can't reach the server. The picture wasn't sent."
            default: sendError = "The picture couldn't be sent."
            }
        }
    }


    /// Sends a picked file, recording or clip as it is. The message shows as a local echo while uploading.
    public func sendFile(data: Data, filename: String, mimeType: String) async {
        guard !isSendingFile else { return }
        isSendingFile = true
        sendError = nil
        defer { isSendingFile = false }
        do {
            try await coordinator.sendFile(OutgoingFile(data: data, filename: filename, mimeType: mimeType))
        } catch {
            switch error {
            case .invalidInput("FILE_TOO_LARGE"): sendError = "That file is too large to send."
            case .invalidInput("EMPTY_FILE"): sendError = "That file is empty."
            case .invalidInput: sendError = "That file can't be sent."
            case .network(retryable: true): sendError = "Can't reach the server. The file wasn't sent."
            default: sendError = "The file couldn't be sent."
            }
        }
    }

    public func reportFileTooLarge() { sendError = "That file is too large to send." }
    public func reportFileUnreadable() { sendError = "That file couldn't be read." }
    public func dismissSendError() { sendError = nil }

    /// Decoding and re-encoding a photo is real work; it runs off the main actor.
    @concurrent private static func prepare(_ preparer: any ImagePreparing, _ data: Data, _ filename: String) async throws(HaloError) -> OutgoingImage {
        try preparer.prepare(data: data, filename: filename)
    }

    /// Sends a sticker from the sticker panel. Throws so the panel can say it failed.
    public func sendSticker(_ sticker: Sticker) async throws(HaloError) {
        try await coordinator.sendSticker(sticker)
    }

    /// Sends a KLIPY GIF or sticker: a message whose body is the item's KLIPY URL, unchanged (KLIPY's rules forbid
    /// re-hosting its media). It goes through the SDK like any text, so it is end-to-end encrypted in an encrypted room;
    /// recipients' Halo plays it inline, other clients show the link (COMPOSER_PANELS §6, D98). Replies when a reply is set.
    public func sendKlipy(_ item: KlipyItem) async throws(HaloError) {
        guard KlipyLink.mediaURL(in: item.shared.url) != nil else { throw .invalidInput("NOT_KLIPY_MEDIA") }
        if let id = replyingTo?.eventID {
            try await coordinator.reply(to: id, text: item.shared.url)
            replyingTo = nil
        } else {
            try await coordinator.send(item.shared.url)
        }
    }

    /// Whether KLIPY links in this room play inline: KLIPY is configured and the room's media previews are on (loading
    /// the file tells KLIPY's CDN this device's address, like any link preview).
    public var showsKlipyMedia: Bool { klipy != nil && !previewsHidden }

    /// A KLIPY file for a message, loaded directly from KLIPY (memory cache only).
    public func klipyMedia(_ url: URL) async -> Data? {
        guard showsKlipyMedia, let klipy else { return nil }
        return try? await klipy.media(url)
    }

    /// The emoji panel's delete key: removes the last character (a whole emoji, flags and families included).
    public func deleteBackward() {
        guard !draft.isEmpty else { return }
        draft.removeLast()
    }

    /// Reacts to a confirmed message, or removes the user's reaction.
    public func toggleReaction(on row: TimelineRow, key: String) async {
        guard let id = row.eventID else { return }
        await perform { try await coordinator.toggleReaction(on: id, key: key) }
    }

    /// Opens the emoji picker for a confirmed message.
    public func beginReactionPicker(_ row: TimelineRow) {
        guard row.eventID != nil else { return }
        reactionTarget = row
    }

    public func cancelReactionPicker() { reactionTarget = nil }

    /// Reacts with `key` to the picker's message and closes the picker.
    public func pickReaction(_ key: String) async {
        guard let target = reactionTarget else { return }
        recordRecentEmoji(key)
        reactionTarget = nil
        await toggleReaction(on: target, key: key)
    }

    /// Extracts the first native emoji from arbitrary keyboard input (e.g. the iOS system emoji keyboard)
    /// and reacts to the active `reactionTarget`.
    @discardableResult
    public func pickCustomReaction(from input: String) async -> Bool {
        guard let emoji = NativeEmoji.firstEmoji(in: input) else { return false }
        await pickReaction(emoji)
        return true
    }

    /// Deletes the user's own confirmed message.
    public func delete(_ row: TimelineRow) async {
        guard let id = row.eventID, row.isOwn else { return }
        await perform { try await coordinator.delete(event: id) }
    }

    /// Sends a message that failed again.
    public func retry(_ row: TimelineRow) async {
        guard let id = row.failedLocalID else { return }
        await perform { try await coordinator.retrySend(localID: id) }
    }

    /// Deletes a message that failed to send, so it never goes out.
    public func discard(_ row: TimelineRow) async {
        guard let id = row.failedLocalID else { return }
        await perform { try await coordinator.abortSend(localID: id) }
    }

    /// Loads an own, confirmed text message into the composer for editing.
    public func beginEdit(_ row: TimelineRow) {
        guard row.canEdit, let id = row.eventID else { return }
        if editing == nil { stashedDraft = draft }
        editing = id
        replyingTo = nil
        draft = row.source?.body ?? row.text.replacingOccurrences(of: " (edited)", with: "")
    }

    /// Makes the next send a reply to a confirmed message.
    public func beginReply(_ row: TimelineRow) {
        guard row.eventID != nil else { return }
        editing = nil
        replyingTo = row
    }

    public func cancelReply() { replyingTo = nil }

    public func cancelEdit() {
        editing = nil
        draft = stashedDraft
        stashedDraft = ""
    }

    func perform(_ action: () async throws -> Void) async {
        do { try await action() } catch {
            sendError = (error as? HaloError) == .forbidden ? "You can only change your own messages." : "That didn't work. Try again."
        }
    }

    /// Whether the photo is shown: always, unless the media preview setting hides photos and this one wasn't tapped.
    public func showsPreview(of image: TimelineRow.Image) -> Bool { !previewsHidden || revealedPreviews.contains(image.ref) }

    /// The user tapped a hidden photo: it loads and stays shown while the room is open.
    public func revealPreview(of image: TimelineRow.Image) { revealedPreviews.insert(image.ref) }

    /// A sender's profile picture, small; `nil` if it can't be loaded (the view keeps the initial).
    public func avatarData(_ ref: MediaRef) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(ref, width: 64, height: 64)
    }

    /// Largest sticker file the timeline plays by itself (STICKERS FR-8/FR-9; the same limit as the panel).
    static let stickerAutoplayLimit = 1_000_000

    /// The full file of a sticker, so an animated one can play; `nil` when it can't be loaded or is too large to autoplay.
    /// The view decides whether it is animated and whether motion is allowed.
    public func stickerContent(for image: TimelineRow.Image) async -> Data? {
        guard let media, let full = try? await media.content(image.ref), full.count <= Self.stickerAutoplayLimit else { return nil }
        return full
    }

    /// Thumbnail bytes for an image row, or `nil` if it can't be loaded (the row then shows a placeholder).
    public func thumbnail(for image: TimelineRow.Image) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(image.ref, width: 600, height: 600)
    }

    /// One photo shown in the full-screen zoomable timeline photo viewer (MEDIA_ATTACHMENTS FR-1).
    public struct PhotoViewerItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let image: TimelineRow.Image
        public let caption: String?
        public let sender: String?
        public let time: String?
    }

    /// All non-sticker photo rows currently loaded in the timeline, in chronological order (for swipe navigation).
    public var viewerPhotos: [PhotoViewerItem] {
        guard case .live(let rows, _, _, _) = content else { return [] }
        return rows.compactMap { row in
            guard let image = row.image, !row.isSticker else { return nil }
            let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return PhotoViewerItem(
                id: row.id,
                image: image,
                caption: trimmed.isEmpty ? nil : trimmed,
                sender: row.isOwn ? "You" : row.sender,
                time: row.time
            )
        }
    }

    /// Full-resolution bytes for the full-screen photo viewer, falling back to thumbnail if full download fails.
    public func fullImageData(for image: TimelineRow.Image) async -> Data? {
        guard let media else { return nil }
        if let full = try? await media.content(image.ref) { return full }
        return try? await media.thumbnail(image.ref, width: 1200, height: 1200)
    }

    /// Exports a photo from the full-screen viewer to a temporary file for ShareLink / Save Image.
    public func exportViewerPhoto(_ item: PhotoViewerItem) async -> URL? {
        guard let data = await fullImageData(for: item.image) else { return nil }
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("halo-photo-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let raw = (item.caption ?? "photo.jpg")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let base = raw.isEmpty ? "photo.jpg" : raw
            let filename = base.contains(".") ? base : "\(base).jpg"
            let url = dir.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

}
