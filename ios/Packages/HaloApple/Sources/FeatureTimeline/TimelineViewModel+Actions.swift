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
    /// A file is written to disk as it arrives (M19-5), so the limit is disk and patience, not memory.
    public nonisolated static let openSizeLimit = 300 * 1024 * 1024

    public func openFile(_ row: TimelineRow) async {
        let target: TimelineRow.FileTile?
        if let file = row.file {
            target = file
        } else if let audio = row.audio {
            target = TimelineRow.FileTile(
                kind: .audio, name: Self.audioFilename(from: audio.name, mimeType: audio.mimeType),
                detail: "", ref: audio.ref, size: audio.size, thumbnail: nil)
        } else {
            target = nil
        }
        guard let file = target, media != nil, openingRow == nil else { return }
        openFileError = nil
        if let size = file.size, size > Self.openSizeLimit {
            openFileError = "This file is too large to open here yet (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
            return
        }
        openingRow = row.id
        let rowID = row.id
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.openingRow == rowID {
                    self.openingRow = nil
                    self.openFileTask = nil
                }
            }
            do {
                let url = try await self.downloadFileToTemp(file)
                if Task.isCancelled || self.openingRow != rowID {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())  // best-effort: cancelled download temp folder
                    return
                }
                self.openedFile = OpenedFile(url: url)
            } catch is CancellationError {
                return
            } catch HaloError.cancelled {
                return
            } catch {
                guard !Task.isCancelled, self.openingRow == rowID else { return }
                self.openFileError = (error as? HaloError) == .network(retryable: true)
                    ? "Can't reach the server. The file wasn't opened."
                    : "The file couldn't be opened."
            }
        }
        openFileTask = task
        await task.value
    }

    /// Cancels an in-flight file download (AC-MED-3, M19-5); leaves no error and cleans up any temporary folder.
    public func cancelOpenFile() {
        openFileTask?.cancel()
        openFileTask = nil
        openingRow = nil
    }

    /// Downloads a file attachment into a sanitized temporary directory (used by Quick Look and drag-out).
    public func downloadFileToTemp(_ file: TimelineRow.FileTile) async throws -> URL {
        guard let media else { throw HaloError.notFound }
        if let size = file.size, size > Self.openSizeLimit {
            throw HaloError.invalidInput("File exceeds the size limit")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("halo-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The name comes from the sender: the port keeps only its last path component so it can't leave the folder.
        do {
            return try await media.file(file.ref, name: file.name, mimeType: nil, in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)  // best-effort: a half-made temporary folder; the system clears the rest
            throw error
        }
    }

    /// Quick Look was dismissed: the temporary copy is deleted.
    public func closeFile() {
        if let url = openedFile?.url { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        openedFile = nil
    }

    // MARK: Inline audio and voice playback (MEDIA_ATTACHMENTS FR-3, M20-2)

    /// Starts, pauses, resumes, or cancels inline playback for an audio or voice message bubble.
    public func toggleAudioPlayback(for row: TimelineRow) {
        guard let audio = row.audio else { return }
        audioPlayer.togglePlay(
            itemID: row.id,
            announcedDuration: audio.duration,
            isVoice: audio.isVoice,
            hasWaveform: audio.waveform != nil
        ) { [weak self] in
            guard let self else { throw HaloError.cancelled }
            return try await self.downloadAudioToTemp(audio)
        }
    }

    /// Streams an audio attachment straight to a temporary file with a player-friendly file extension (M19-5, M20-2).
    public func downloadAudioToTemp(_ audio: TimelineRow.Audio) async throws -> URL {
        guard let media else { throw HaloError.notFound }
        if let size = audio.size, size > Self.openSizeLimit {
            throw HaloError.invalidInput("Audio exceeds the size limit")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = Self.audioFilename(from: audio.name, mimeType: audio.mimeType)
        do {
            return try await media.file(audio.ref, name: filename, mimeType: audio.mimeType, in: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)  // best-effort: half-made temporary folder
            throw error
        }
    }

    /// Ensures an audio file saved to disk carries an extension `AVURLAsset` recognises (Element voice notes often use
    /// `"Voice message"` as `body` with `mimeType: "audio/ogg"`).
    static func audioFilename(from rawName: String, mimeType: String?) -> String {
        let last = rawName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let base = last.isEmpty || last == "." || last == ".." ? "audio" : last
        let existingExt = (base as NSString).pathExtension.lowercased()
        let knownAudioExtensions: Set<String> = ["m4a", "mp4", "ogg", "oga", "opus", "mp3", "wav", "aac", "caf", "flac", "aiff", "aif", "webm"]
        if knownAudioExtensions.contains(existingExt) { return base }

        let mime = (mimeType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let inferredExt: String = switch mime {
        case "audio/ogg", "application/ogg", "audio/opus": "ogg"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        case "audio/aac": "aac"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/x-caf", "audio/caf": "caf"
        case "audio/aiff", "audio/x-aiff": "aiff"
        case "audio/webm": "webm"
        default: ""
        }
        guard !inferredExt.isEmpty else { return base }
        return "\(base).\(inferredExt)"
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
            let outgoing = photo.with(caption: caption)
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
        await sendOutgoingFile(OutgoingFile(data: data, filename: filename, mimeType: mimeType))
    }

    /// Sends a recorded voice message with MSC3245 voice flag, duration, and MSC1767 waveform metadata (M20-2).
    public func sendVoice(data: Data, duration: TimeInterval, waveform: [Float]) async {
        await sendOutgoingFile(OutgoingFile(
            data: data, filename: "Voice message.m4a", mimeType: "audio/mp4",
            duration: duration, waveform: waveform, isVoiceMessage: true))
    }

    private func sendOutgoingFile(_ file: OutgoingFile) async {
        guard !isSendingFile else { return }
        isSendingFile = true
        sendError = nil
        defer { isSendingFile = false }
        do {
            try await coordinator.sendFile(file)
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

    public struct PinnedMessage: Identifiable, Equatable, Sendable {
        public var id: EventID { eventID }
        public let eventID: EventID
        public let sender: String
        public let avatar: MediaRef?
        public let preview: String
        public let time: String?
    }

    /// Pinned messages for the floating banner and Pinned Messages sheet, newest pinned first.
    public var pinnedMessages: [PinnedMessage] {
        let rows: [TimelineRow] = if case .live(let r, _, _, _) = content { r } else { [] }
        let byEvent = Dictionary(rows.compactMap { row in row.eventID.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        return pinnedEventIDs.reversed().map { id in
            if let row = byEvent[id] {
                let preview: String
                if let location = row.location { preview = location.title }
                else if let audio = row.audio { preview = audio.isVoice ? "Voice message" : audio.name }
                else if let file = row.file { preview = file.name }
                else if row.isSticker { preview = "Sticker" }
                else if row.image != nil, !row.showsText { preview = "Photo" }
                else { preview = row.text }
                return PinnedMessage(
                    eventID: id,
                    sender: row.sender ?? (row.isOwn ? "You" : "Message"),
                    avatar: row.avatar,
                    preview: preview,
                    time: row.time
                )
            }
            return PinnedMessage(
                eventID: id,
                sender: "Pinned message",
                avatar: nil,
                preview: "Tap to jump to message",
                time: nil
            )
        }
    }

    public func isPinned(_ row: TimelineRow) -> Bool {
        guard let id = row.eventID else { return false }
        return pinnedEventIDs.contains(id)
    }

    /// Pins or unpins a confirmed message in the room (`m.room.pinned_events` or personal pins fallback).
    public func togglePin(_ row: TimelineRow) async {
        guard let id = row.eventID else { return }
        if pinnedEventIDs.contains(id) {
            await unpin(eventID: id)
        } else {
            await pin(eventID: id)
        }
    }

    public func pin(eventID id: EventID) async {
        sendError = nil
        do {
            try await coordinator.pin(event: id)
            var updated = await coordinator.pinnedEventIDs()
            if !updated.contains(id) { updated.append(id) }
            pinnedEventIDs = updated
        } catch {
            sendError = error == .network(retryable: true)
                ? "Can't reach the server. Pin change wasn't saved."
                : "Couldn't pin this message."
        }
    }

    public func unpin(eventID id: EventID) async {
        sendError = nil
        do {
            try await coordinator.unpin(event: id)
            pinnedEventIDs = await coordinator.pinnedEventIDs().filter { $0 != id }
        } catch {
            sendError = error == .network(retryable: true)
                ? "Can't reach the server. Pin change wasn't saved."
                : "Couldn't unpin this message."
        }
    }

    /// Sends a static location from the attachment panel (D100). Returns `true` when sent; a failure is shown in the composer.
    @discardableResult
    public func sendLocation(_ location: OutgoingLocation) async -> Bool {
        sendError = nil
        do {
            try await coordinator.sendLocation(location)
            return true
        } catch {
            sendError = error == .network(retryable: true) ? "Can't reach the server. The location wasn't sent." : "The location couldn't be sent."
            return false
        }
    }

    /// Sends the Article editor's Markdown as one message (D101): the ordinary text path, where the SDK turns the Markdown
    /// into the formatted body (encrypted in encrypted rooms). Replies when a reply is set. Returns `true` when sent; the
    /// draft is kept on failure.
    @discardableResult
    public func sendArticle() async -> Bool {
        let text = articleDraft
        sendError = nil
        guard ArticleMarkdown.canSend(text) else {
            sendError = text.count > ArticleMarkdown.maximumLength
                ? "The article is too long. Keep it under \(ArticleMarkdown.maximumLength.formatted()) characters." : nil
            return false
        }
        do {
            if let id = replyingTo?.eventID {
                try await coordinator.reply(to: id, text: text)
                replyingTo = nil
            } else {
                try await coordinator.send(text)
            }
            articleDraft = ""
            return true
        } catch {
            sendError = error == .network(retryable: true) ? "Can't reach the server. Your article was kept." : "The article couldn't be sent."
            return false
        }
    }

    /// Starts a poll from the attachment panel (D100). Returns `true` when sent; otherwise says why.
    @discardableResult
    public func createPoll(_ poll: OutgoingPoll) async -> Bool {
        sendError = nil
        do {
            try await coordinator.createPoll(poll)
            return true
        } catch {
            switch error {
            case .invalidInput("POLL_DUPLICATE_ANSWERS"): sendError = "Two answers are the same."
            case .invalidInput: sendError = "A poll needs a question and at least two answers."
            case .network(retryable: true): sendError = "Can't reach the server. The poll wasn't sent."
            default: sendError = "The poll couldn't be sent."
            }
            return false
        }
    }

    public func reportFileTooLarge() { sendError = "That file is too large to send." }
    public func reportFileUnreadable() { sendError = "That file couldn't be read." }
    public func dismissSendError() { sendError = nil }

    /// Accepts the contact's current identity (FR-7). The notice goes when the SDK reports the new state.
    public func acceptIdentity(of user: UserID) async {
        do { try await coordinator.acceptIdentity(of: user) } catch {
            sendError = "Couldn't accept the new identity. Try again."
        }
    }

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
        return try? await klipy.media(url)  // best-effort: a picture that can't load shows its placeholder; nothing changes
    }

    /// The emoji panel's delete key: removes the last character (a whole emoji, flags and families included).
    public func deleteBackward() {
        guard !draft.isEmpty else { return }
        draft.removeLast()
    }

    /// Reacts to a confirmed message, or removes the user's reaction.
    public func toggleReaction(on row: TimelineRow, key: String) async {
        guard let id = row.eventID else { return }
        await perform("react:\(id.rawValue):\(key)") { try await coordinator.toggleReaction(on: id, key: key) }
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
        await perform("delete:\(id.rawValue)") { try await coordinator.delete(event: id) }
    }

    /// Sends a message that failed again.
    public func retry(_ row: TimelineRow) async {
        guard let id = row.failedLocalID else { return }
        await perform("retry:\(id)") { try await coordinator.retrySend(localID: id) }
    }

    /// Sends a message again after the person accepted the encryption risk that stopped it (AC-SEC-2).
    public func sendAnyway(_ row: TimelineRow) async {
        guard let id = row.failedLocalID, row.canSendAnyway else { return }
        await perform("sendAnyway:\(id)") { try await coordinator.sendAnyway(localID: id) }
    }

    /// Deletes a message that failed to send, so it never goes out.
    public func discard(_ row: TimelineRow) async {
        guard let id = row.failedLocalID else { return }
        await perform("abort:\(id)") { try await coordinator.abortSend(localID: id) }
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

    /// Runs one change to a message; a second tap on the same one while it runs does nothing (AC-REL-4), and a failure is said.
    func perform(_ key: String, _ action: () async throws -> Void) async {
        await actions.run(key) {
            do { try await action() } catch {
                sendError = (error as? HaloError) == .forbidden ? "You can only change your own messages." : "That didn't work. Try again."
            }
        }
    }

    /// Whether the photo is shown: always, unless the media preview setting hides photos and this one wasn't tapped.
    public func showsPreview(of image: TimelineRow.Image) -> Bool { !previewsHidden || revealedPreviews.contains(image.ref) }

    /// The user tapped a hidden photo: it loads and stays shown while the room is open.
    public func revealPreview(of image: TimelineRow.Image) { revealedPreviews.insert(image.ref) }

    /// A sender's profile picture, small; `nil` if it can't be loaded (the view keeps the initial).
    public func avatarData(_ ref: MediaRef) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(ref, width: 64, height: 64)  // best-effort: a picture that can't load shows its placeholder; nothing changes
    }

    /// Largest sticker file the timeline plays by itself (STICKERS FR-8/FR-9; the same limit as the panel).
    static let stickerAutoplayLimit = 1_000_000

    /// The full file of a sticker, so an animated one can play; `nil` when it can't be loaded or is too large to autoplay.
    /// The view decides whether it is animated and whether motion is allowed.
    public func stickerContent(for image: TimelineRow.Image) async -> Data? {
        guard let media, let full = try? await media.content(image.ref), full.count <= Self.stickerAutoplayLimit else { return nil }  // best-effort: a picture that can't load shows its placeholder; nothing changes
        return full
    }

    /// Thumbnail bytes for an image row, or `nil` if it can't be loaded (the row then shows a placeholder).
    /// Prefers a precomputed thumbnail (`thumbnailRef`) or own cached upload (`MediaFormat::File` in the SDK's encrypted store)
    /// so own thumbnails aren't downloaded again after a restart (M19-5).
    public func thumbnail(for image: TimelineRow.Image) async -> Data? {
        if let known = thumbnailMemory.data(for: image.ref) { return known }
        guard let media else { return nil }
        let loaded: Data?
        if let thumbRef = image.thumbnailRef, let direct = try? await media.cachedContent(thumbRef) {  // best-effort: falls back to server thumbnail
            loaded = direct
        } else if image.isOwn, let ownCached = try? await media.cachedContent(image.ref) {  // best-effort: SDK caches own uploads under MediaFormat::File (M19-5)
            loaded = ownCached
        } else {
            loaded = try? await media.thumbnail(image.ref, width: 600, height: 600)  // best-effort: a picture that can't load shows its placeholder; nothing changes
        }
        guard let loaded else { return nil }
        thumbnailMemory.store(loaded, for: image.ref)
        return loaded
    }

    /// The picture already shown for this reference, for a view's first frame (no waiting, no placeholder).
    func cachedThumbnail(for image: TimelineRow.Image) -> Data? { thumbnailMemory.data(for: image.ref) }

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

    /// Streams a full-resolution photo straight to a temporary file on disk for the viewer (M19-5),
    /// falling back to a thumbnail written to disk if the full download fails.
    public func fullImageFile(for image: TimelineRow.Image, filename: String = "photo.jpg") async -> URL? {
        guard let media else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-viewer-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = Self.photoFilename(from: filename)
            if let url = try? await media.file(image.ref, name: safeName, mimeType: nil, in: dir) {  // best-effort: falls back to thumbnail
                return url
            }
            if let thumb = try? await media.thumbnail(image.ref, width: 1200, height: 1200) {  // best-effort: fallback preview
                let url = dir.appendingPathComponent(safeName)
                try thumb.write(to: url, options: .atomic)
                return url
            }
            try? FileManager.default.removeItem(at: dir)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// Full-resolution bytes for on-demand actions such as Save as Sticker; streams via `fullImageFile` so the SDK file cache is reused.
    public func fullImageData(for image: TimelineRow.Image) async -> Data? {
        guard let url = await fullImageFile(for: image) else { return nil }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try? Data(contentsOf: url)
    }

    /// Streams a photo from the full-screen viewer directly to a temporary file on disk for ShareLink / Save Image (M19-5).
    public func exportViewerPhoto(_ item: PhotoViewerItem) async -> URL? {
        guard let media else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-photo-\(UUID().uuidString)", isDirectory: true)
        let filename = Self.photoFilename(from: item.caption ?? "photo.jpg")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let url = try? await media.file(item.image.ref, name: filename, mimeType: nil, in: dir) {  // best-effort: falls back to thumbnail export
                return url
            }
            if let thumb = try? await media.thumbnail(item.image.ref, width: 1200, height: 1200) {  // best-effort: caller handles nil export URL
                let url = dir.appendingPathComponent(filename)
                try thumb.write(to: url, options: .atomic)
                return url
            }
            try? FileManager.default.removeItem(at: dir)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    private static func photoFilename(from rawName: String) -> String {
        let raw = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let base = raw.isEmpty ? "photo.jpg" : raw
        return base.contains(".") ? base : "\(base).jpg"
    }

}
