import Foundation
import HaloApplication
import HaloBotRendering
import HaloDomain
import HaloFoundation
import Observation

extension TimelineViewModel {
    func apply(_ status: TimelineCoordinator.Status) {
        switch status {
        case .idle, .opening:
            content = .opening
        case .live(let snapshot):
            // A focused timeline is an excerpt: it says nothing about what was read or which messages are the newest.
            isFocused = snapshot.focus != nil
            focusReachedEnd = snapshot.reachedEnd
            if !isFocused { readTracker.update(items: snapshot.items) }
            lastItems = snapshot.items
            botTasks = botTracker(snapshot.items)
            if let botActivity, let room, !botSenders.isEmpty, !isFocused {
                let items = snapshot.items, senders = botSenders
                Task { await botActivity.observe(room: room, items: items, botSenders: senders) }
            }
            botTapped.subtract(botTasks.completed)
            botUnanswered.subtract(botTasks.completed)
            var profiles: [UserID: (name: String?, avatar: MediaRef?)] = [:]
            for item in snapshot.items {
                if case .event(let event) = item.content, let sender = event.sender, !event.isOwn, event.senderName != nil || event.senderAvatar != nil {
                    profiles[sender] = (event.senderName, event.senderAvatar)
                }
            }
            readerProfiles = profiles
            senderNames = Self.senderNames(snapshot.items)
            let rows = Self.collapsingStateRuns(Self.groupingRuns(mappedRows(snapshot.items), items: snapshot.items), items: snapshot.items)
            // A photo you sent changes its reference when the server confirms it: the picture on screen becomes the entry
            // for the new reference, so nothing is loaded again.
            for change in TimelineThumbnailMemory.changedReferences(rows: rows, known: &knownPhotoRefs) {
                thumbnailMemory.adopt(change.old, as: change.new)
            }
            // Wait until there is something to land on: a message, or the whole (message-less) history. The first snapshots of a
            // freshly opened room hold only the start marker and state events.
            let hasMessage = snapshot.items.contains { item in
                if case .event(let event) = item.content { switch event.kind { case .text, .notice, .emote, .media, .sticker: return true; default: return false } }
                return false
            }
            if isFocused {
                landed = true
                trackedTailID = rows.last?.id
            } else if !landed, !rows.isEmpty, hasMessage || (snapshot.reachedStart && !snapshot.isPaginating) {
                landed = true
                trackedTailID = rows.last?.id
                // Always open at the newest message (D95); the first unread one stays marked, and the "Jump to unread" pill
                // takes the reader up to it.
                landingRow = rows.last?.id
                landingIsUnread = false
                if let unread = Self.firstUnreadItemID(snapshot.items, readThrough: readThroughAtOpen) {
                    unreadMarkerID = unread
                }
            } else {
                updateDetachedCount(for: rows)
                if !landed, !snapshot.reachedStart, !snapshot.isPaginating, snapshot.paginationError == nil,
                   openingPages < Self.maxOpeningPages {
                    openingPages += 1
                    Task { await loadEarlier() }
                }
            }
            if !isFocused { reportOwnMessage(snapshot.items) }
            reevaluateSeen()
            typingText = Self.typingText(snapshot.typing, items: snapshot.items)
            identityNotices = Self.identityNotices(snapshot.identityAlerts, items: snapshot.items)
            content = .live(
                rows: rows,
                isPaginating: snapshot.isPaginating,
                canLoadEarlier: !snapshot.reachedStart,
                paginationError: snapshot.paginationError.map { _ in "Couldn't load earlier messages." })
        case .failed(let error):
            content = .failed(error == .notFound ? "This room isn't available." : "The timeline couldn't be loaded.")
        }
        noteIfShowable()
    }

    /// Counts incoming messages appended after `trackedTailID` while scrolled up; ignores back-pagination and edits.
    func updateDetachedCount(for rows: [TimelineRow]) {
        guard landed else {
            trackedTailID = rows.last?.id
            return
        }
        guard !isAtBottom else {
            newSinceDetached = 0
            trackedTailID = rows.last?.id
            return
        }
        let tail = rows.last?.id
        guard tail != trackedTailID else { return }
        if let prev = trackedTailID, let idx = rows.lastIndex(where: { $0.id == prev }) {
            let added = rows[(idx + 1)...].filter { row in
                !row.isOwn && [.message, .notice, .emote, .placeholder].contains(row.style)
            }.count
            newSinceDetached += added
        }
        trackedTailID = tail
    }

    /// Sending a message means the user has read up to it (MESSAGING FR-6, rule E1b): once the newest own message (in
    /// timeline order, not by timestamp, R-06) has a server event ID it becomes the read position.
    func reportOwnMessage(_ items: [TimelineItem]) {
        guard isPresented, let receipts, let room else { return }
        var newest: (id: EventID, time: Date)?
        for item in items {
            guard case .event(let event) = item.content, event.isOwn, let id = event.eventID else { continue }
            newest = (id, event.timestamp)
        }
        guard let newest, newest.id != reportedOwn else { return }
        reportedOwn = newest.id
        Task { await receipts.reportSeen(room: room, event: newest.id, timestamp: newest.time, advancesOrder: true) }
    }

    /// One notice per contact, named from the timeline's senders (a user without one is shown by user ID).
    static func identityNotices(_ alerts: [IdentityAlert], items: [TimelineItem]) -> [IdentityNotice] {
        guard !alerts.isEmpty else { return [] }
        var names: [UserID: String] = [:]
        for item in items {
            if case .event(let event) = item.content, let sender = event.sender, let name = event.senderName { names[sender] = name }
        }
        return alerts.map { alert in
            let name = names[alert.user] ?? alert.user.rawValue
            switch alert.kind {
            case .changed:
                return IdentityNotice(user: alert.user, isSerious: false, text: "\(name)'s security identity changed. They may have a new device, or someone else may be pretending to be them. Messages you send now go to the new identity.", actionTitle: "Accept")
            case .verifiedBefore:
                return IdentityNotice(user: alert.user, isSerious: true, text: "\(name) was verified, and now has a different identity. Check with them another way before you send anything private.", actionTitle: "Trust the new identity")
            }
        }
    }

    /// Names come from the timeline's senders; a user without one is shown by user ID (never invented).
    static func typingText(_ users: [UserID], items: [TimelineItem]) -> String? {
        guard !users.isEmpty else { return nil }
        var names: [UserID: String] = [:]
        for item in items {
            if case .event(let event) = item.content, let sender = event.sender, let name = event.senderName { names[sender] = name }
        }
        let labels = users.map { names[$0] ?? $0.rawValue }
        switch labels.count {
        case 1: return "\(labels[0]) is typing…"
        case 2: return "\(labels[0]) and \(labels[1]) are typing…"
        default: return "Several people are typing…"
        }
    }

    /// Unnamed room-setting changes (creation, power levels, join rules …) show once per stretch of room events
    /// (TIMELINE FR-2: state events grouped). Membership changes in between stay visible and don't start a new stretch,
    /// so a new room's setup reads "The room was updated", then who joined, instead of repeating the line.
    static func collapsingStateRuns(_ rows: [TimelineRow], items: [TimelineItem]) -> [TimelineRow] {
        var result: [TimelineRow] = []
        var stretchHasSettings = false
        for (row, item) in zip(rows, items) {
            let isSettings: Bool = { if case .event(let e) = item.content, e.kind == .otherState { true } else { false } }()
            let isRoomEvent: Bool = { if case .event(let e) = item.content, case .membership = e.kind { true } else { isSettings } }()
            if !isRoomEvent { stretchHasSettings = false }
            if isSettings {
                if stretchHasSettings { continue }
                stretchHasSettings = true
            }
            result.append(row)
        }
        return result
    }

    nonisolated static let settingsText = "The room was updated"

    /// Messages from the same person within this time of their previous one form a group (one name and picture).
    static let runGap: TimeInterval = 5 * 60

    /// Marks a message that directly follows the same person's previous message (no divider or other row between, within
    /// `runGap`), so the view shows the name and picture once per group and the time once, under its last message.
    static func groupingRuns(_ rows: [TimelineRow], items: [TimelineItem]) -> [TimelineRow] {
        var result = rows
        let isMessage: (TimelineRow) -> Bool = { $0.style == .message || $0.style == .ownMessage || $0.style == .placeholder }
        for index in result.indices.dropFirst() where isMessage(result[index]) && result[index - 1].style == result[index].style {
            guard case .event(let event) = items[index].content, case .event(let previous) = items[index - 1].content,
                  let sender = event.sender, sender == previous.sender,
                  event.timestamp.timeIntervalSince(previous.timestamp) < runGap else { continue }
            result[index].continuesRun = true
            result[index - 1].endsRun = false
        }
        return result
    }

    func botTracker(_ items: [TimelineItem]) -> BotTaskTracker {
        guard !botSenders.isEmpty else { return BotTaskTracker([]) }
        var messages: [BotTaskTracker.Message] = []
        for item in items {
            guard case .event(let event) = item.content, let card = botCard(event), let sender = event.sender?.rawValue else { continue }
            messages.append(.init(bot: sender, eventID: event.eventID, card: card))
        }
        return BotTaskTracker(messages)
    }

    /// The card for a message from an allowlisted bot whose HTML a parser recognises.
    func botCard(_ event: TimelineEvent) -> BotCard? {
        guard let sender = event.sender?.rawValue, botSenders.contains(sender), let html = event.formattedBody else { return nil }
        let card = BotTemplates.parse(html)
        if card == nil, let id = event.eventID?.rawValue { unrecognisedBotMessages?.record(eventID: id) }
        return card
    }

    func plainSource(_ event: TimelineEvent, _ body: String) -> TimelineRow.Source {
        .init(sender: event.sender?.rawValue, eventID: event.eventID?.rawValue, body: body, formattedBody: event.formattedBody)
    }

    static func localpart(_ user: UserID) -> String {
        let raw = user.rawValue
        return raw.hasPrefix("@") ? String(raw.dropFirst().prefix { $0 != ":" }) : raw
    }

    /// What `row(_:)` reads besides the item: sender names, readers' profiles and the bot allowlist. A change drops every cached row.
    private func mappingContext() -> Int {
        var hasher = Hasher()
        hasher.combine(senderNames)
        hasher.combine(botSenders)
        var profiles = 0
        for (user, profile) in readerProfiles {
            var entry = Hasher()
            entry.combine(user)
            entry.combine(profile.name)
            entry.combine(profile.avatar?.token)
            profiles &+= entry.finalize()  // a sum, so the order of the dictionary doesn't matter
        }
        hasher.combine(profiles)
        return hasher.finalize()
    }

    /// The rows for `items`: a cached row is reused when its item is equal and the mapping context is the same, so one new
    /// message makes one row (M19-2). The result is the same as `items.map(row)`.
    func mappedRows(_ items: [TimelineItem]) -> [TimelineRow] {
        let context = mappingContext()
        if context != rowCacheContext {
            rowCache.removeAll(keepingCapacity: true)
            rowCacheContext = context
        }
        var next: [TimelineItemID: (item: TimelineItem, row: TimelineRow)] = [:]
        next.reserveCapacity(items.count)
        let rows = items.map { item -> TimelineRow in
            if let hit = rowCache[item.id], hit.item == item {
                next[item.id] = hit
                return hit.row
            }
            rowsMapped += 1
            let made = row(item)
            next[item.id] = (item, made)
            return made
        }
        rowCache = next
        return rows
    }

    func row(_ item: TimelineItem) -> TimelineRow {
        var row = baseRow(item)
        if case .event(let event) = item.content {
            if !event.isOwn { row.avatar = event.senderAvatar }
            switch event.kind {
            case .text(_, true), .notice(_, true), .emote(_, true): row.isEdited = true
            default: break
            }
            if event.isOwn, row.style == .ownMessage {
                // Every kind of own message (text, photo, file, sticker, location, poll) reports its send state the same way.
                row.delivery = TimelineRow.Delivery(sendState: event.sendState, readCount: event.readBy.count)
                row.status = Self.status(of: event.sendState, failure: event.sendFailure, names: senderNames)
                row.failedLocalID = Self.failedID(event)
                row.canSendAnyway = event.sendFailure?.canSendAnyway == true && row.failedLocalID != nil
            }
            if event.isOwn, row.style == .ownMessage, event.sendState == .sent {
                row.seenBy = event.readBy.count
                row.allReaders = event.readBy.map { user in
                    let known = readerProfiles[user]
                    return TimelineRow.Reader(id: user.rawValue, name: known?.name ?? Self.localpart(user), avatar: known?.avatar)
                }
            }
            if row.style == .message || row.style == .ownMessage { row.time = timeFormatter.string(from: event.timestamp) }
        }
        return row
    }

    /// The day divider, the way Messages titles days: "Today", "Yesterday", the weekday for the past week,
    /// then the day and month this year and the full date before that.
    static func dayTitle(_ date: Date, now: Date, formatter: DateFormatter) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        calendar.locale = formatter.locale
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let startOfToday = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let style = Date.FormatStyle(locale: formatter.locale, calendar: calendar, timeZone: formatter.timeZone)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < startOfToday {
            return date.formatted(style.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
        }
        return formatter.string(from: date)
    }

    func baseRow(_ item: TimelineItem) -> TimelineRow {
        let id = item.id.rawValue
        switch item.content {
        case .virtual(.dateDivider(let date)):
            return TimelineRow(id: id, style: .divider, sender: nil, text: Self.dayTitle(date, now: Date(), formatter: dateFormatter))
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
                    status: Self.status(of: event.sendState), eventID: event.eventID, isOwn: event.isOwn,
                    reactions: Self.chips(event.reactions), reply: Self.reply(event.replyTo),
                    styled: event.formattedBody.map { HTMLText.attributed($0) + AttributedString(edited ? " (edited)" : "") },
                    failedLocalID: Self.failedID(event),
                    source: .init(sender: event.sender?.rawValue, eventID: event.eventID?.rawValue, body: body, formattedBody: event.formattedBody),
                    card: botCard(event))
            case .notice(let body, let edited):
                return TimelineRow(
                    id: id, style: .notice, sender: name, text: edited ? "\(body) (edited)" : body,
                    eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions),
                    styled: event.formattedBody.map { HTMLText.attributed($0) + AttributedString(edited ? " (edited)" : "") },
                    source: plainSource(event, body), card: botCard(event))
            case .emote(let body, let edited):
                return TimelineRow(
                    id: id, style: .emote, sender: nil, text: edited ? "\(name) \(body) (edited)" : "\(name) \(body)",
                    eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions),
                    source: plainSource(event, body))
            case .media(let attachment):
                let style: TimelineRow.Style = event.isOwn ? .ownMessage : .message
                if attachment.kind == .image, let source = attachment.source {
                    let ratio = Self.aspectRatio(width: attachment.width, height: attachment.height)
                    return TimelineRow(
                        id: id, style: style, sender: name, text: attachment.body,
                        image: .init(
                            ref: source, aspectRatio: ratio, blurhash: attachment.blurhash,
                            thumbnailRef: attachment.thumbnail, isOwn: event.isOwn),
                        eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions), source: plainSource(event, attachment.body))
                }
                let label = "[\(Self.label(attachment.kind))] \(attachment.body)"
                guard let source = attachment.source else { return TimelineRow(id: id, style: style, sender: name, text: label) }
                return TimelineRow(
                    id: id, style: style, sender: name, text: label, eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions),
                    file: .init(kind: attachment.kind, name: attachment.body, detail: Self.fileDetail(attachment), ref: source, size: attachment.size,
                        thumbnail: attachment.kind == .video ? attachment.thumbnail.map {
                            .init(ref: $0, aspectRatio: Self.aspectRatio(width: attachment.width, height: attachment.height), blurhash: attachment.blurhash)
                        } : nil), source: plainSource(event, attachment.body))
            case .sticker(let body, let source):
                guard let source else {
                    return TimelineRow(
                        id: id, style: event.isOwn ? .ownMessage : .message, sender: name,
                        text: body.isEmpty ? "Sticker (can't be shown)" : "[Sticker] \(body)", eventID: event.eventID, isOwn: event.isOwn)
                }
                return TimelineRow(
                    id: id, style: event.isOwn ? .ownMessage : .message, sender: name, text: body, image: .init(ref: source, aspectRatio: 1),
                    eventID: event.eventID, isOwn: event.isOwn, reactions: Self.chips(event.reactions), isSticker: true, source: plainSource(event, body))
            case .redacted:
                return TimelineRow(id: id, style: .placeholder, sender: name, text: "Message deleted", isOwn: event.isOwn)
            case .undecryptable(let reason):
                return TimelineRow(id: id, style: .placeholder, sender: name, text: Self.text(for: reason), isOwn: event.isOwn)
            case .membership(_, let displayName, let change):
                let who = displayName ?? name
                return TimelineRow(id: id, style: .state, sender: nil, text: "\(who) \(Self.phrase(change))")
            case .location(let body, let geoURI):
                let text = "📍 \(body.isEmpty ? "Shared location" : body)"
                let url = Self.mapsURL(geoURI: geoURI)
                var styled = AttributedString(text)
                if let url { styled.link = url }
                let locationCard: TimelineRow.Location? = Self.parseCoordinates(geoURI: geoURI).map { coords in
                    TimelineRow.Location(
                        latitude: coords.latitude,
                        longitude: coords.longitude,
                        title: Self.locationTitle(from: body),
                        subtitle: Self.formattedCoordinates(latitude: coords.latitude, longitude: coords.longitude),
                        mapsURL: url
                    )
                }
                return TimelineRow(
                    id: id, style: event.isOwn ? .ownMessage : .message, sender: name, text: text, eventID: event.eventID, isOwn: event.isOwn,
                    reactions: Self.chips(event.reactions), styled: styled, location: locationCard, source: plainSource(event, body))
            case .poll(let question, let options, let ended):
                let lines = options.map { "• \($0.text) — \($0.votes) \($0.votes == 1 ? "vote" : "votes")" }
                let text = (["📊 \(question)"] + lines + [ended ? "Poll ended" : "Voting isn't available in Halo yet"]).joined(separator: "\n")
                return TimelineRow(
                    id: id, style: event.isOwn ? .ownMessage : .message, sender: name, text: text, eventID: event.eventID, isOwn: event.isOwn,
                    reactions: Self.chips(event.reactions))
            case .call:
                return TimelineRow(id: id, style: .state, sender: nil, text: "\(name) started a call — Halo can't join calls")
            case .otherState:
                return TimelineRow(id: id, style: .state, sender: nil, text: Self.settingsText)
            case .unsupported:
                return TimelineRow(id: id, style: .placeholder, sender: name, text: "Unsupported event", isOwn: event.isOwn)
            }
        }
    }

    /// Parses `geo:lat,lon[;u=…]` coordinates; `nil` when missing or out of range.
    static func parseCoordinates(geoURI: String) -> (latitude: Double, longitude: Double)? {
        guard geoURI.hasPrefix("geo:") else { return nil }
        guard let head = geoURI.dropFirst(4).split(separator: ";").first else { return nil }
        let coords = head.split(separator: ",")
        guard coords.count >= 2, let lat = Double(coords[0]), let lon = Double(coords[1]), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
    }

    /// An Apple Maps link for a `geo:lat,lon[;u=…]` URI; `nil` when the coordinates are missing or out of range.
    static func mapsURL(geoURI: String) -> URL? {
        guard let coords = parseCoordinates(geoURI: geoURI) else { return nil }
        return URL(string: "https://maps.apple.com/?ll=\(coords.latitude),\(coords.longitude)&q=Shared%20location")
    }

    private static func locationTitle(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Shared Location" }
        if trimmed.hasPrefix("Pinned location:") { return "Pinned Location" }
        if trimmed.hasPrefix("Location:") { return "Current Location" }
        return trimmed
    }

    private static func formattedCoordinates(latitude: Double, longitude: Double) -> String {
        let latDir = latitude >= 0 ? "N" : "S"
        let lonDir = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), latDir, abs(longitude), lonDir)
    }

    static func reply(_ preview: ReplyPreview?) -> TimelineRow.Reply? {
        preview.map { TimelineRow.Reply(eventID: $0.eventID, sender: $0.senderName, snippet: $0.snippet) }
    }

    static func chips(_ reactions: [ReactionSummary]) -> [TimelineRow.Chip] {
        reactions.map { TimelineRow.Chip(key: $0.key, count: $0.count, reactedByMe: $0.reactedByMe) }
    }

    /// The local ID of a failed own echo, the only kind the user can retry or delete.
    static func failedID(_ event: TimelineEvent) -> String? {
        if case .failed = event.sendState, event.eventID == nil { return event.localID }
        return nil
    }

    /// The status line of an own message; a refused send says why in plain words (AC-SEC-2).
    static func status(of state: SendState, failure: SendFailure?, names known: [UserID: String]) -> String? {
        guard case .failed = state, let failure else { return status(of: state) }
        func names(_ users: [UserID]) -> String {
            let labels = users.map { known[$0] ?? $0.rawValue }
            switch labels.count {
            case 0: return "Someone in this chat"
            case 1: return labels[0]
            case 2: return "\(labels[0]) and \(labels[1])"
            default: return "\(labels[0]) and \(labels.count - 1) others"
            }
        }
        switch failure {
        case .unverifiedDevices(let users): return "Not sent: \(names(users)) has a device you haven't verified."
        case .identityChanged(let users): return "Not sent: \(names(users)) was verified, and now has a different identity."
        case .needsVerification: return "Not sent: verify this device first (Settings → Security)."
        case .sessionExpired: return "Not sent: sign in again to send."
        case .mediaGone: return "Not sent: the picture or file is no longer on this device."
        case .other: return status(of: state)
        }
    }

    /// Display names of the senders in the loaded timeline.
    static func senderNames(_ items: [TimelineItem]) -> [UserID: String] {
        var names: [UserID: String] = [:]
        for item in items {
            if case .event(let event) = item.content, let sender = event.sender, let name = event.senderName { names[sender] = name }
        }
        return names
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
        // Short enough for one line in a bubble; each still says what the reader can expect or do.
        case .unknown: "Waiting for this message's key"
        case .sentBeforeJoining: "Sent before you joined, so you can't read it."
        case .keysNotShared: "Waiting for the sender's device to share the key."
        case .senderVerificationProblem: "Not shown: the sender isn't verified."
        case .backupDisabled: "Enter your recovery key to read older messages."
        }
    }

    /// "PDF · 1.2 MB", "0:42 · 3.4 MB": what is known about the file, without inventing the rest.
    static func aspectRatio(width: Int?, height: Int?) -> Double? {
        guard let width, let height, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    static func fileDetail(_ attachment: MediaAttachment) -> String {
        var parts: [String] = []
        if let duration = attachment.duration, duration > 0, attachment.kind != .file {
            let total = Int(duration.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        if attachment.kind == .file {
            let ext = (attachment.body as NSString).pathExtension
            if !ext.isEmpty { parts.append(ext.uppercased()) }
            else if let mime = attachment.mimeType, let sub = mime.split(separator: "/").last { parts.append(sub.uppercased()) }
        }
        if let size = attachment.size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    static func label(_ kind: MediaKind) -> String {
        switch kind {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .file: "File"
        }
    }

    static func phrase(_ change: MembershipChange) -> String {
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

/// A contact's changed identity as the composer shows it (ENCRYPTION_AND_DEVICES FR-7).
public struct IdentityNotice: Identifiable, Equatable, Sendable {
    public var id: UserID { user }
    public let user: UserID
    /// A contact who had been verified: shown in the warning colour.
    public let isSerious: Bool
    public let text: String
    public let actionTitle: String
}
