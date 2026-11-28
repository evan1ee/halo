import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// Owns composer state for a timeline: draft, article draft, mentions, emoji suggestions/recents,
/// reply/edit/reaction-picker state, pending photo/video staging, and send flags/errors (audit F-08).
@MainActor @Observable
public final class TimelineComposerModel {
    /// Maximum number of photos that can be attached together in one batch.
    public static let maxPendingPhotos = 10
    /// Maximum number of videos that can be attached together in one batch.
    public static let maxPendingVideos = 5

    /// The Article editor's text (D101): kept while the editor is closed, cleared once the article was sent.
    public var articleDraft = ""

    /// The message being typed. Cleared only once the send was accepted, so a failure never loses the text.
    public var draft = "" {
        didSet {
            guard draft != oldValue, editing == nil, !isRestoringDraft else { return }
            onDraftEdited?(draft, mentionQuery != nil)
        }
    }

    /// People that can be mentioned in this room; loaded the first time the user types `@`.
    public internal(set) var members: [RoomMember] = []
    var membersRequested = false
    /// Users picked from the suggestions for the message being written.
    public internal(set) var pendingMentions: [Mention] = []

    /// Most recently used native emoji for reactions and composer input (persisted per device, newest first, max 16).
    public internal(set) var recentEmoji: [String] = UserDefaults.standard.stringArray(forKey: "halo.emoji.recents") ?? []

    public internal(set) var isSending = false
    public internal(set) var sendError: String?
    /// The own message being edited, or `nil` when the composer writes a new message.
    public internal(set) var editing: EventID?
    /// The unsent text that was in the composer when an edit began; it comes back when the edit ends.
    var stashedDraft = ""
    /// The message an emoji is being picked for, or `nil` when the picker is closed.
    public internal(set) var reactionTarget: TimelineRow?
    /// The message the next send replies to, or `nil`.
    public internal(set) var replyingTo: TimelineRow?
    /// Pending photo/video staging state.
    public internal(set) var isSendingImage = false
    public internal(set) var pendingPhotos: [OutgoingImage] = []
    public internal(set) var isSendingVideo = false
    public internal(set) var pendingVideos: [OutgoingFile] = []
    public internal(set) var isSendingFile = false

    var isRestoringDraft = false
    /// Called by `draft.didSet` when user input changes the draft (not during edits or draft restoration).
    @ObservationIgnored var onDraftEdited: ((String, Bool) -> Void)?

    public init() {}

    public var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingPhotos.isEmpty || !pendingVideos.isEmpty)
            && !isSending && !isSendingImage && !isSendingVideo
    }

    /// The first pending photo, or `nil` when none are attached.
    public var pendingPhoto: OutgoingImage? { pendingPhotos.first }

    /// The text after a trailing `@` that starts a word in the draft, or `nil` when the user isn't typing a mention.
    public var mentionQuery: String? {
        guard editing == nil, let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: \.isWhitespace), query.count <= 30 else { return nil }
        return String(query)
    }

    /// Up to five members matching `mentionQuery`.
    public var mentionSuggestions: [RoomMember] {
        guard let query = mentionQuery else { return [] }
        let needle = query.lowercased()
        let matches = needle.isEmpty ? members : members.filter { member in
            member.mentionName.lowercased().contains(needle) || member.user.rawValue.lowercased().dropFirst().hasPrefix(needle)
        }
        return Array(matches.prefix(5))
    }

    /// Replaces the `@query` being typed with the member's name and remembers the mention for the send.
    public func pickMention(_ member: RoomMember) {
        guard mentionQuery != nil, let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@\(member.mentionName) "
        pendingMentions.removeAll { $0.user == member.user }
        pendingMentions.append(Mention(user: member.user, name: member.mentionName))
    }

    /// Up to six native emoji matching a trailing `:shortcode` query in `draft`.
    public var emojiSuggestions: [NativeEmoji.Entry] {
        NativeEmoji.shortcodeSuggestions(forDraft: draft)?.entries ?? []
    }

    /// Replaces the trailing `:shortcode` in `draft` with the selected native emoji and records it as recent.
    public func pickEmojiSuggestion(_ entry: NativeEmoji.Entry) {
        guard let match = NativeEmoji.shortcodeSuggestions(forDraft: draft) else { return }
        draft.replaceSubrange(match.range, with: entry.emoji + " ")
        recordRecentEmoji(entry.emoji)
    }

    /// Inserts a native emoji into the composer draft and records it as recent.
    public func insertEmoji(_ emoji: String) {
        draft += emoji
        recordRecentEmoji(emoji)
    }

    /// The emoji panel's delete key: removes the last character (a whole emoji, flags and families included).
    public func deleteBackward() {
        guard !draft.isEmpty else { return }
        draft.removeLast()
    }

    func recordRecentEmoji(_ emoji: String) {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentEmoji.removeAll { $0 == trimmed }
        recentEmoji.insert(trimmed, at: 0)
        if recentEmoji.count > 16 { recentEmoji.removeLast(recentEmoji.count - 16) }
        UserDefaults.standard.set(recentEmoji, forKey: "halo.emoji.recents")
    }

    /// Restores a persisted draft without triggering typing/save callbacks.
    func applyRestoredDraft(_ text: String) {
        guard draft.isEmpty, editing == nil, !text.isEmpty else { return }
        isRestoringDraft = true
        draft = text
        isRestoringDraft = false
    }

    /// Loads an own, confirmed text message into the composer for editing.
    public func beginEdit(_ row: TimelineRow) {
        guard row.canEdit, let id = row.eventID else { return }
        if editing == nil { stashedDraft = draft }
        editing = id
        replyingTo = nil
        draft = row.source?.body ?? row.text.replacingOccurrences(of: " (edited)", with: "")
    }

    public func cancelEdit() {
        editing = nil
        draft = stashedDraft
        stashedDraft = ""
    }

    func finishEdit() {
        editing = nil
        draft = stashedDraft
        stashedDraft = ""
    }

    /// Makes the next send a reply to a confirmed message.
    public func beginReply(_ row: TimelineRow) {
        guard row.eventID != nil else { return }
        editing = nil
        replyingTo = row
    }

    public func cancelReply() { replyingTo = nil }

    /// Opens the emoji picker for a confirmed message.
    public func beginReactionPicker(_ row: TimelineRow) {
        guard row.eventID != nil else { return }
        reactionTarget = row
    }

    public func cancelReactionPicker() { reactionTarget = nil }

    /// Drops one pending photo at `index`; the typed text and other photos stay.
    public func removePendingPhoto(at index: Int) {
        guard pendingPhotos.indices.contains(index) else { return }
        pendingPhotos.remove(at: index)
    }

    /// Drops all held photos; the typed text stays.
    public func removePendingPhoto() { pendingPhotos.removeAll() }

    /// Drops one pending video at `index` and deletes its staged temporary copy.
    public func removePendingVideo(at index: Int) {
        guard pendingVideos.indices.contains(index) else { return }
        let removed = pendingVideos.remove(at: index)
        Self.cleanUpStagedVideo(removed)
    }

    /// Drops all pending videos and deletes their staged temporary copies.
    public func removePendingVideos() {
        let items = pendingVideos
        pendingVideos.removeAll()
        for item in items { Self.cleanUpStagedVideo(item) }
    }

    static func cleanUpStagedVideo(_ video: OutgoingFile) {
        guard let url = video.fileURL else { return }
        let dir = url.deletingLastPathComponent()
        if dir.lastPathComponent.hasPrefix("halo-pending-video-") {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    public func reportFileTooLarge() { sendError = "That file is too large to send." }
    public func reportFileUnreadable() { sendError = "That file couldn't be read." }
    public func dismissSendError() { sendError = nil }
}
