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

    /// A downloaded video clip on disk, played in `VideoPlayerSheet` (M20-3).
    public struct OpenedVideo: Identifiable, Equatable {
        public let id = UUID()
        public let url: URL
        public let title: String
        public let caption: String?
    }

    /// A file is written to disk as it arrives (M19-5), so the limit is disk and patience, not memory.
    public nonisolated static let openSizeLimit = TimelineMediaModel.openSizeLimit

    public func openFile(_ row: TimelineRow) async { await mediaState.openFile(row) }
    public func cancelOpenFile() { mediaState.cancelOpenFile() }
    public func downloadFileToTemp(_ file: TimelineRow.FileTile) async throws -> URL { try await mediaState.downloadFileToTemp(file) }
    public func closeFile() { mediaState.closeFile() }

    // MARK: Full-screen video playback (MEDIA_ATTACHMENTS FR-2, M19-5, M20-3)

    public func openVideo(_ row: TimelineRow) async { await mediaState.openVideo(row) }
    public func cancelOpenVideo() { mediaState.cancelOpenVideo() }
    public func closeVideo() { mediaState.closeVideo() }
    public func downloadVideoToTemp(_ video: TimelineRow.Video) async throws -> URL { try await mediaState.downloadVideoToTemp(video) }
    public func showsPreview(of video: TimelineRow.Video) -> Bool { mediaState.showsPreview(of: video) }
    public func revealPreview(of video: TimelineRow.Video) { mediaState.revealPreview(of: video) }

    // MARK: Inline audio and voice playback (MEDIA_ATTACHMENTS FR-3, M20-2)

    public func toggleAudioPlayback(for row: TimelineRow) { mediaState.toggleAudioPlayback(for: row) }
    public func downloadAudioToTemp(_ audio: TimelineRow.Audio) async throws -> URL { try await mediaState.downloadAudioToTemp(audio) }
    static func audioFilename(from rawName: String, mimeType: String?) -> String { TimelineMediaModel.audioFilename(from: rawName, mimeType: mimeType) }
    public func dismissOpenFileError() { mediaState.dismissOpenFileError() }

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
        if !pendingPhotos.isEmpty || !pendingVideos.isEmpty { await sendPendingMedia(); return }
        let text = draft
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            if let editing {
                try await coordinator.edit(event: editing, newText: text)
                composer.finishEdit()
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
    public static let maxPendingPhotos = TimelineComposerModel.maxPendingPhotos

    /// The first pending photo, or `nil` when none are attached.
    public var pendingPhoto: OutgoingImage? { composer.pendingPhoto }

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
    public func removePendingPhoto(at index: Int) { composer.removePendingPhoto(at: index) }

    /// Drops all held photos; the typed text stays.
    public func removePendingPhoto() { composer.removePendingPhoto() }

    /// `true` when the composer can attach videos with poster + caption (M20-3).
    public var canSendVideos: Bool { videoPreparer != nil }

    /// Maximum number of videos that can be attached together in one batch.
    public static let maxPendingVideos = TimelineComposerModel.maxPendingVideos

    /// Stages a video file from Gallery or Files off the main actor (poster thumbnail, portrait/landscape dimensions, duration)
    /// so the user can add a caption before sending (M20-3).
    public func attachVideo(fileURL: URL, filename: String, mimeType: String) async {
        guard let videoPreparer, !isSendingVideo, pendingVideos.count < Self.maxPendingVideos else { return }
        isSendingVideo = true
        sendError = nil
        defer { isSendingVideo = false }
        let stagedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-pending-video-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
            let safeName = VideoDisplayMetrics.videoFilename(from: filename, mimeType: mimeType)
            let stagedURL = stagedDir.appendingPathComponent(safeName)
            try FileManager.default.copyItem(at: fileURL, to: stagedURL)
            let prepared = try await videoPreparer.prepare(fileURL: stagedURL, filename: safeName, mimeType: mimeType)
            if prepared.fileURL != stagedURL {
                try? FileManager.default.removeItem(at: stagedDir)
            }
            pendingVideos.append(prepared)
        } catch let error as HaloError {
            try? FileManager.default.removeItem(at: stagedDir)
            switch error {
            case .invalidInput("FILE_TOO_LARGE"): sendError = "That video is too large to send."
            case .invalidInput("EMPTY_FILE"): sendError = "That video is empty."
            default: sendError = "That video couldn't be prepared."
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedDir)
            sendError = "That video couldn't be read."
        }
    }

    /// Drops one pending video at `index` and deletes its staged temporary copy.
    public func removePendingVideo(at index: Int) { composer.removePendingVideo(at: index) }

    /// Drops all pending videos and deletes their staged temporary copies.
    public func removePendingVideos() { composer.removePendingVideos() }

    /// Sends all pending photos and videos in order, attaching the composer text as the first item's caption.
    func sendPendingMedia() async {
        if !pendingPhotos.isEmpty {
            await sendPendingPhotos()
            guard sendError == nil else { return }
        }
        guard !pendingVideos.isEmpty else { return }
        isSendingVideo = true
        sendError = nil
        defer { isSendingVideo = false }
        var caption: String? = {
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        while let video = pendingVideos.first {
            let outgoing = video.with(caption: caption)
            do {
                try await coordinator.sendFile(outgoing)
                pendingVideos.removeFirst()
                TimelineComposerModel.cleanUpStagedVideo(video)
                if caption != nil {
                    caption = nil
                    draft = ""
                }
            } catch {
                sendError = error == .network(retryable: true)
                    ? "Can't reach the server. The video wasn't sent."
                    : "The video couldn't be sent."
                return
            }
        }
    }

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
                else if let poll = row.poll { preview = "📊 \(poll.question)" }
                else if let video = row.video { preview = video.caption ?? "Video" }
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

    /// Casts or changes the user's vote on a confirmed poll (MESSAGING FR-10, AC-M5, M20-4).
    /// Marks the vote as pending immediately and keeps it pending until the server snapshot echoes it or sending fails.
    public func votePoll(_ row: TimelineRow, optionID: String) async {
        guard let eventID = row.eventID, let poll = row.poll, !poll.ended, !endingPolls.contains(eventID) else { return }
        let current = pendingPollVotes[eventID] ?? poll.ownSelectedIDs
        guard let next = poll.nextSelection(tapping: optionID, current: current) else { return }
        let previousPending = pendingPollVotes[eventID]
        await actions.run("poll-vote:\(eventID.rawValue)") {
            pollErrors[eventID] = nil
            pendingPollVotes[eventID] = next
            do {
                try await coordinator.votePoll(pollEventID: eventID, answers: next)
            } catch {
                if let previousPending {
                    pendingPollVotes[eventID] = previousPending
                } else {
                    pendingPollVotes.removeValue(forKey: eventID)
                }
                if case .network = error as? HaloError {
                    pollErrors[eventID] = "Can't reach the server. Your vote wasn't sent."
                } else {
                    pollErrors[eventID] = "Couldn't send your vote."
                }
            }
        }
    }

    /// Ends the user's own confirmed poll (MESSAGING FR-10, M20-4).
    public func endPoll(_ row: TimelineRow) async {
        guard row.isOwn, let eventID = row.eventID, let poll = row.poll, !poll.ended else { return }
        await actions.run("poll-end:\(eventID.rawValue)") {
            pollErrors[eventID] = nil
            endingPolls.insert(eventID)
            do {
                try await coordinator.endPoll(pollEventID: eventID, fallbackText: poll.endFallbackText())
            } catch {
                endingPolls.remove(eventID)
                if case .network = error as? HaloError {
                    pollErrors[eventID] = "Can't reach the server. The poll wasn't ended."
                } else {
                    pollErrors[eventID] = "Couldn't end this poll."
                }
            }
        }
    }

    /// Clears pending poll votes and ending flags once the server timeline snapshot confirms them.
    func reconcilePendingPolls(_ items: [TimelineItem]) {
        guard !pendingPollVotes.isEmpty || !endingPolls.isEmpty else { return }
        for item in items {
            guard case .event(let event) = item.content,
                  let id = event.eventID,
                  case .poll(let details) = event.kind else { continue }
            if let pending = pendingPollVotes[id],
               details.ended || Set(details.ownSelectedIDs) == Set(pending) {
                pendingPollVotes.removeValue(forKey: id)
            }
            if details.ended {
                endingPolls.remove(id)
            }
        }
    }

    public func reportFileTooLarge() { composer.reportFileTooLarge() }
    public func reportFileUnreadable() { composer.reportFileUnreadable() }
    public func dismissSendError() { composer.dismissSendError() }

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
    public func deleteBackward() { composer.deleteBackward() }

    /// Reacts to a confirmed message, or removes the user's reaction.
    public func toggleReaction(on row: TimelineRow, key: String) async {
        guard let id = row.eventID else { return }
        await perform("react:\(id.rawValue):\(key)") { try await coordinator.toggleReaction(on: id, key: key) }
    }

    /// Opens the emoji picker for a confirmed message.
    public func beginReactionPicker(_ row: TimelineRow) { composer.beginReactionPicker(row) }

    public func cancelReactionPicker() { composer.cancelReactionPicker() }

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
    public func beginEdit(_ row: TimelineRow) { composer.beginEdit(row) }

    /// Makes the next send a reply to a confirmed message.
    public func beginReply(_ row: TimelineRow) { composer.beginReply(row) }

    public func cancelReply() { composer.cancelReply() }

    public func cancelEdit() { composer.cancelEdit() }

    /// Runs one change to a message; a second tap on the same one while it runs does nothing (AC-REL-4), and a failure is said.
    func perform(_ key: String, _ action: () async throws -> Void) async {
        await actions.run(key) {
            do { try await action() } catch {
                sendError = (error as? HaloError) == .forbidden ? "You can only change your own messages." : "That didn't work. Try again."
            }
        }
    }

    /// Whether the photo is shown: always, unless the media preview setting hides photos and this one wasn't tapped.
    public func showsPreview(of image: TimelineRow.Image) -> Bool { mediaState.showsPreview(of: image) }

    /// The user tapped a hidden photo: it loads and stays shown while the room is open.
    public func revealPreview(of image: TimelineRow.Image) { mediaState.revealPreview(of: image) }

    /// A sender's profile picture, small; `nil` if it can't be loaded (the view keeps the initial).
    public func avatarData(_ ref: MediaRef) async -> Data? { await mediaState.avatarData(ref) }

    /// Largest sticker file the timeline plays by itself (STICKERS FR-8/FR-9; the same limit as the panel).
    static let stickerAutoplayLimit = TimelineMediaModel.stickerAutoplayLimit

    /// The full file of a sticker, so an animated one can play; `nil` when it can't be loaded or is too large to autoplay.
    public func stickerContent(for image: TimelineRow.Image) async -> Data? { await mediaState.stickerContent(for: image) }

    /// Thumbnail bytes for an image row, or `nil` if it can't be loaded (the row then shows a placeholder).
    public func thumbnail(for image: TimelineRow.Image) async -> Data? { await mediaState.thumbnail(for: image) }

    /// The picture already shown for this reference, for a view's first frame (no waiting, no placeholder).
    func cachedThumbnail(for image: TimelineRow.Image) -> Data? { mediaState.cachedThumbnail(for: image) }

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

    public func fullImageFile(for image: TimelineRow.Image, filename: String = "photo.jpg") async -> URL? {
        await mediaState.fullImageFile(for: image, filename: filename)
    }

    public func fullImageData(for image: TimelineRow.Image) async -> Data? {
        await mediaState.fullImageData(for: image)
    }

    public func exportViewerPhoto(_ item: PhotoViewerItem) async -> URL? {
        await mediaState.exportViewerPhoto(item)
    }
}
