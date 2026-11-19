import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// One displayed row. Text is prepared here so the view only lays it out.
public struct TimelineRow: Equatable, Identifiable, Sendable {
    public enum Style: Equatable, Sendable { case message, ownMessage, notice, emote, placeholder, state, divider, marker }
    public let id: String
    public let style: Style
    public let sender: String?
    public let text: String
    /// An image to show above the text (the filename or caption), loaded through the view model.
    public let image: Image?
    /// "Sending…" or "Not sent" for an own message that the server hasn't confirmed; `nil` once it is sent.
    public let status: String?

    public struct Image: Equatable, Sendable {
        public let ref: MediaRef
        /// Width / height, when the sender gave dimensions; the view falls back to 4:3.
        public let aspectRatio: Double?
    }

    init(id: String, style: Style, sender: String?, text: String, image: Image? = nil, status: String? = nil) {
        self.status = status
        self.id = id
        self.style = style
        self.sender = sender
        self.text = text
        self.image = image
    }
}

/// Presents one room's timeline from `TimelineCoordinator` (docs/features/TIMELINE.md). M1: read-only.
@MainActor @Observable
public final class TimelineViewModel {
    public enum Content: Equatable {
        case opening
        case live(rows: [TimelineRow], isPaginating: Bool, canLoadEarlier: Bool, paginationError: String?)
        case failed(String)
    }

    public private(set) var content: Content = .opening
    /// The message being typed. Cleared only once the send was accepted, so a failure never loses the text.
    public var draft = ""
    public private(set) var isSending = false
    public private(set) var sendError: String?

    public var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending }

    private let coordinator: TimelineCoordinator
    private let media: MediaLoader?
    private var observation: Task<Void, Never>?
    private let dateFormatter: DateFormatter

    public init(coordinator: TimelineCoordinator, media: MediaLoader? = nil, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.coordinator = coordinator
        self.media = media
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        dateFormatter = formatter
    }

    isolated deinit { observation?.cancel() }

    /// Opens the timeline and follows it. Call when the screen appears.
    public func start() async {
        guard observation == nil else { return }
        let statuses = await coordinator.statuses()
        observation = Task { [weak self] in
            for await status in statuses { self?.apply(status) }
        }
        await coordinator.open()
    }

    /// Closes the timeline. Call when the screen disappears.
    public func stop() async {
        observation?.cancel()
        observation = nil
        await coordinator.close()
    }

    public func loadEarlier() async { await coordinator.paginateBackwards() }

    /// Sends the draft (MESSAGING FR-2). The message shows up in the timeline as a local echo.
    public func send() async {
        guard canSend else { return }
        let text = draft
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            try await coordinator.send(text)
            draft = ""
        } catch {
            sendError = error == .network(retryable: true) ? "Can't reach the server. Your message was kept." : "The message couldn't be sent."
        }
    }

    /// Thumbnail bytes for an image row, or `nil` if it can't be loaded (the row then shows a placeholder).
    public func thumbnail(for image: TimelineRow.Image) async -> Data? {
        guard let media else { return nil }
        return try? await media.thumbnail(image.ref, width: 600, height: 600)
    }

    func apply(_ status: TimelineCoordinator.Status) {
        switch status {
        case .idle, .opening:
            content = .opening
        case .live(let snapshot):
            content = .live(
                rows: Self.collapsingStateRuns(snapshot.items.map(row), items: snapshot.items),
                isPaginating: snapshot.isPaginating,
                canLoadEarlier: !snapshot.reachedStart,
                paginationError: snapshot.paginationError.map { _ in "Couldn't load earlier messages." })
        case .failed(let error):
            content = .failed(error == .notFound ? "This room isn't available." : "The timeline couldn't be loaded.")
        }
    }

    /// A run of unnamed room-setting changes (creation, power levels, join rules …) becomes one row
    /// (TIMELINE FR-2: state events grouped). Membership changes stay visible.
    static func collapsingStateRuns(_ rows: [TimelineRow], items: [TimelineItem]) -> [TimelineRow] {
        var result: [TimelineRow] = []
        for (row, item) in zip(rows, items) {
            let isSettings: Bool = { if case .event(let e) = item.content, e.kind == .otherState { true } else { false } }()
            if isSettings, let last = result.last, last.style == .state, last.text == Self.settingsText { continue }
            result.append(row)
        }
        return result
    }

    static let settingsText = "The room was updated"

    func row(_ item: TimelineItem) -> TimelineRow {
        let id = item.id.rawValue
        switch item.content {
        case .virtual(.dateDivider(let date)):
            return TimelineRow(id: id, style: .divider, sender: nil, text: dateFormatter.string(from: date))
        case .virtual(.readMarker):
            return TimelineRow(id: id, style: .marker, sender: nil, text: "New messages")
        case .virtual(.timelineStart):
            return TimelineRow(id: id, style: .state, sender: nil, text: "This is the start of the conversation.")
        case .event(let event):
            let name = event.senderName ?? event.sender.map { $0.rawValue } ?? "Unknown"
            switch event.kind {
            case .text(let body, let edited):
                return TimelineRow(
                    id: id, style: event.isOwn ? .ownMessage : .message, sender: name, text: edited ? "\(body) (edited)" : body,
                    status: Self.status(of: event.sendState))
            case .notice(let body, _):
                return TimelineRow(id: id, style: .notice, sender: name, text: body)
            case .emote(let body, _):
                return TimelineRow(id: id, style: .emote, sender: nil, text: "\(name) \(body)")
            case .media(let attachment):
                let style: TimelineRow.Style = event.isOwn ? .ownMessage : .message
                if attachment.kind == .image, let source = attachment.source {
                    let ratio: Double? = {
                    guard let width = attachment.width, let height = attachment.height, height > 0 else { return nil }
                    return Double(width) / Double(height)
                }()
                    return TimelineRow(id: id, style: style, sender: name, text: attachment.body, image: .init(ref: source, aspectRatio: ratio))
                }
                return TimelineRow(id: id, style: style, sender: name, text: "[\(Self.label(attachment.kind))] \(attachment.body)")
            case .sticker(let body, _):
                return TimelineRow(id: id, style: .message, sender: name, text: "[Sticker] \(body)")
            case .redacted:
                return TimelineRow(id: id, style: .placeholder, sender: name, text: "Message deleted")
            case .undecryptable(let reason):
                return TimelineRow(id: id, style: .placeholder, sender: name, text: Self.text(for: reason))
            case .membership(_, let displayName, let change):
                let who = displayName ?? name
                return TimelineRow(id: id, style: .state, sender: nil, text: "\(who) \(Self.phrase(change))")
            case .otherState:
                return TimelineRow(id: id, style: .state, sender: nil, text: Self.settingsText)
            case .unsupported:
                return TimelineRow(id: id, style: .placeholder, sender: name, text: "Unsupported event")
            }
        }
    }

    static func status(of state: SendState) -> String? {
        switch state {
        case .sent: nil
        case .sending: "Sending…"
        case .failed(let recoverable): recoverable ? "Not sent yet — will retry" : "Not sent"
        }
    }

    /// The reason is shown honestly; where the user can do something about it, the text says what.
    static func text(for reason: UTDReason) -> String {
        switch reason {
        case .unknown: "Unable to decrypt this message. It will appear if the keys arrive."
        case .sentBeforeJoining: "This message was sent before you joined, so you can't read it."
        case .keysNotShared: "Unable to decrypt: the sender's device hasn't shared its keys with this device yet."
        case .senderVerificationProblem: "Unable to decrypt: the sender's identity has changed or isn't verified."
        case .backupDisabled: "Unable to decrypt this older message. Verify this device with your recovery key to load your key backup."
        }
    }

    private static func label(_ kind: MediaKind) -> String {
        switch kind {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .file: "File"
        }
    }

    private static func phrase(_ change: MembershipChange) -> String {
        switch change {
        case .joined: "joined"
        case .left: "left"
        case .invited: "was invited"
        case .kicked: "was removed"
        case .banned: "was banned"
        case .unbanned: "was unbanned"
        case .invitationRejected: "declined the invitation"
        case .invitationRevoked: "had the invitation withdrawn"
        case .knocked: "asked to join"
        case .other: "changed their membership"
        }
    }
}
