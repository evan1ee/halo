import Foundation
import HaloDomain
import HaloFoundation

/// A broken port contract, with the clause that failed.
public struct ContractViolation: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Behaviour every `SessionPort` implementation must show. Run against the fake (here) and against
/// the real adapter on the dev homeserver (M0b), so the fake can't drift from reality
/// (docs/testing/INTEGRATION_TESTS.md §3). The caller provides a server with an existing account.
public enum SessionPortContract {
    public static func verify(
        _ port: any SessionPort, server: String, account: FakeSessionPort.Account
    ) async throws {
        let details: ServerDetails
        do { details = try await port.loginDetails(server: server) } catch {
            throw ContractViolation("loginDetails(\(server)) failed with \(error.code)")
        }
        guard details.supportsPassword else { throw ContractViolation("the contract server must offer password login") }

        let wrong = PasswordCredentials(username: account.localpart, password: account.password + "x", deviceDisplayName: "contract")
        do {
            _ = try await port.loginPassword(wrong, on: details)
            throw ContractViolation("a wrong password must not sign in")
        } catch let error as HaloError {
            guard error == .unauthorized(soft: false) else {
                throw ContractViolation("a wrong password must throw unauthorized(soft: false), got \(error.code)")
            }
        }

        let right = PasswordCredentials(username: account.localpart, password: account.password, deviceDisplayName: "contract")
        let session = try await port.loginPassword(right, on: details)
        guard session.userID.rawValue.hasPrefix("@\(account.localpart):") else {
            throw ContractViolation("the session's user ID must belong to the account that signed in")
        }
        do { try await port.restore(session) } catch {
            throw ContractViolation("restoring a fresh session must succeed, got \(error.code)")
        }
        do { try await port.logout() } catch {
            throw ContractViolation("logout of a fresh session must succeed, got \(error.code)")
        }
    }
}

/// Behaviour every `RoomListPort` implementation must show while the room list settles to
/// `expectedRoomCount` rooms. `maxDiffs` bounds the wait; the caller adds a time limit for real I/O.
public enum RoomListPortContract {
    public static func verify(_ port: any RoomListPort, expectedRoomCount: Int, maxDiffs: Int = 1_000) async throws {
        var rooms: [RoomSummary] = []
        var received = 0
        for await diff in port.rooms(filter: .all) {
            if received == 0 {
                switch diff {
                case .reset, .append: break
                default: throw ContractViolation("the first diff must be .reset or .append, got \(diff)")
                }
            }
            received += 1
            do { try RoomListReducer.apply(diff, to: &rooms) } catch {
                throw ContractViolation("diff #\(received) doesn't apply: \(error.code)")
            }
            guard Set(rooms.map(\.id)).count == rooms.count else {
                throw ContractViolation("duplicate room after diff #\(received)")
            }
            if rooms.count == expectedRoomCount { return }
            if received >= maxDiffs { break }
        }
        throw ContractViolation("the list never reached \(expectedRoomCount) rooms (had \(rooms.count) after \(received) diffs)")
    }
}

/// Behaviour every `TimelinePort` implementation must show for a room whose first events are `expectedBodies`
/// (oldest first, text-like events only; later events are allowed). Run against the fake and against the adapter on the dev homeserver.
public enum TimelinePortContract {
    public static func verify(_ port: any TimelinePort, room: RoomID, expectedBodies: [String], maxDiffs: Int = 1_000) async throws {
        let session: any TimelineSession
        do { session = try await port.open(room: room) } catch {
            throw ContractViolation("open(room:) failed with \(error.code)")
        }

        // A freshly synced room may hold only its newest event: back-paginate, as a real client does, until the start.
        let pagination = Task { () -> HaloError? in
            for _ in 0..<10 {
                do { if try await session.paginateBackwards(count: 20) { return nil } } catch { return (error as? HaloError) ?? .internal(code: "CONTRACT_PAGINATE") }
            }
            return nil
        }
        defer { pagination.cancel() }

        var items: [TimelineItem] = []
        var received = 0
        for await diff in session.items() {
            if received == 0 {
                switch diff {
                case .reset, .append: break
                default: throw ContractViolation("the first diff must be .reset or .append, got \(diff)")
                }
            }
            received += 1
            do { try ListReducer.apply(diff, to: &items) } catch {
                throw ContractViolation("diff #\(received) doesn't apply: \(error.code)")
            }
            guard Set(items.map(\.id)).count == items.count else { throw ContractViolation("duplicate item id after diff #\(received)") }
            if bodies(of: items).starts(with: expectedBodies) { await session.close(); return }
            if received >= maxDiffs { break }
        }
        await session.close()
        pagination.cancel()
        if let failure = await pagination.value { throw ContractViolation("paginateBackwards failed with \(failure.code)") }
        throw ContractViolation("the timeline never showed \(expectedBodies) (had \(bodies(of: items)) after \(received) diffs)")
    }

    /// The text of the text-like events, in order.
    public static func bodies(of items: [TimelineItem]) -> [String] {
        items.compactMap { item in
            guard case .event(let event) = item.content else { return nil }
            switch event.kind {
            case .text(let body, _), .notice(let body, _), .emote(let body, _): return body
            default: return nil
            }
        }
    }

    /// Sending shows a local echo of the text as the user's own message and ends `.sent`; blank text is rejected.
    public static func verifySend(_ port: any TimelinePort, room: RoomID, text: String, maxDiffs: Int = 1_000) async throws {
        let session = try await port.open(room: room)
        let pagination = Task { for _ in 0..<5 { if (try? await session.paginateBackwards(count: 20)) == true { break } } }
        defer { pagination.cancel() }
        do {
            try await session.send(text: "   ")
            throw ContractViolation("blank text must not be sent")
        } catch let error as HaloError {
            guard error == .invalidInput("EMPTY_MESSAGE") else { throw ContractViolation("blank text must throw invalidInput(EMPTY_MESSAGE), got \(error.code)") }
        }
        let stream = session.items()
        do { try await session.send(text: text) } catch { throw ContractViolation("send failed with \(error.code)") }

        var items: [TimelineItem] = []
        var received = 0
        for await diff in stream {
            received += 1
            do { try ListReducer.apply(diff, to: &items) } catch { throw ContractViolation("diff #\(received) doesn't apply: \(error.code)") }
            let mine = items.compactMap { item -> TimelineEvent? in
                guard case .event(let event) = item.content, event.isOwn else { return nil }
                if case .text(let body, _) = event.kind, body == text { return event }
                return nil
            }
            if let last = mine.last, last.sendState == .sent { await session.close(); return }
            if case .failed = mine.last?.sendState { throw ContractViolation("the message failed to send") }
            if received >= maxDiffs { break }
        }
        await session.close()
        throw ContractViolation("the sent message never reached .sent")
    }

    /// React, un-react, edit and delete on the user's own just-sent message (MESSAGING FR-2, TIMELINE FR-7).
    public static func verifyInteractions(_ port: any TimelinePort, room: RoomID, text: String, maxDiffs: Int = 2_000) async throws {
        let session = try await port.open(room: room)
        let pagination = Task { for _ in 0..<5 { if (try? await session.paginateBackwards(count: 20)) == true { break } } }
        defer { pagination.cancel() }
        let stream = session.items()
        try await session.send(text: text)

        var items: [TimelineItem] = []
        var received = 0
        var iterator = stream.makeAsyncIterator()

        /// Waits until the event whose current text is `body` satisfies `predicate`.
        func wait(_ what: String, body: String, _ predicate: (TimelineEvent) -> Bool) async throws -> TimelineEvent {
            while let diff = await iterator.next() {
                received += 1
                do { try ListReducer.apply(diff, to: &items) } catch { throw ContractViolation("diff #\(received) doesn't apply: \(error.code)") }
                for item in items {
                    guard case .event(let event) = item.content, event.isOwn, event.eventID != nil else { continue }
                    let matches: Bool
                    switch event.kind {
                    case .text(let current, _): matches = current == body
                    case .redacted: matches = body == "<redacted>"
                    default: matches = false
                    }
                    if matches && predicate(event) { return event }
                }
                if received >= maxDiffs { break }
            }
            throw ContractViolation("never saw: \(what)")
        }

        let sent = try await wait("the sent message", body: text) { $0.sendState == .sent }
        guard let id = sent.eventID else { throw ContractViolation("a sent event must have an event ID") }

        try await session.toggleReaction(on: id, key: "👍")
        let reacted = try await wait("the reaction", body: text) { $0.reactions.contains { $0.key == "👍" && $0.count == 1 && $0.reactedByMe } }
        _ = reacted
        try await session.toggleReaction(on: id, key: "👍")
        _ = try await wait("the reaction removed", body: text) { $0.reactions.isEmpty }

        let replyText = text + " (reply)"
        try await session.reply(to: id, text: replyText)
        _ = try await wait("the reply quoting the original", body: replyText) { $0.sendState == .sent && $0.replyTo?.eventID == id }

        let edited = text + " (edited)"
        do { try await session.edit(event: id, newText: " ") ; throw ContractViolation("a blank edit must be rejected") } catch let error as HaloError {
            guard error == .invalidInput("EMPTY_MESSAGE") else { throw ContractViolation("a blank edit must throw invalidInput(EMPTY_MESSAGE), got \(error.code)") }
        }
        try await session.edit(event: id, newText: edited)
        _ = try await wait("the edit", body: edited) { event in if case .text(_, let isEdited) = event.kind { isEdited } else { false } }

        try await session.delete(event: id)
        _ = try await wait("the deletion", body: "<redacted>") { _ in true }
        await session.close()
    }

    /// Opening a room the client doesn't know must fail with `.notFound`.
    public static func verifyUnknownRoom(_ port: any TimelinePort, room: RoomID) async throws {
        do {
            let session = try await port.open(room: room)
            await session.close()
            throw ContractViolation("opening an unknown room must throw .notFound")
        } catch let error as HaloError {
            guard error == .notFound else { throw ContractViolation("unknown room must throw .notFound, got \(error.code)") }
        }
    }
}

/// Behaviour every `SyncPort` implementation must show (with a signed-in session behind it).
public enum SyncPortContract {
    /// start → `.running` is reported; start again is harmless; stop ends the loop and is idempotent.
    public static func verify(_ port: any SyncPort) async throws {
        do { try await port.start() } catch { throw ContractViolation("start() failed with \(error.code)") }
        do { try await port.start() } catch { throw ContractViolation("a second start() must be harmless, got \(error.code)") }
        var sawRunning = false
        for await status in port.statuses() {
            if status == .running { sawRunning = true; break }
            if status == .failed { throw ContractViolation("sync failed instead of running") }
        }
        guard sawRunning else { throw ContractViolation("the status stream ended before .running") }
        await port.stop()
        await port.stop()
    }
}

/// Behaviour every `MediaPort` implementation must show for a reference to an existing image.
public enum MediaPortContract {
    public static func verify(_ port: any MediaPort, existing: MediaRef, missing: MediaRef) async throws {
        let thumbnail: Data
        do { thumbnail = try await port.thumbnail(existing, width: 64, height: 64) } catch {
            throw ContractViolation("thumbnail of existing media failed with \(error.code)")
        }
        guard !thumbnail.isEmpty else { throw ContractViolation("the thumbnail is empty") }
        let content: Data
        do { content = try await port.content(existing) } catch {
            throw ContractViolation("content of existing media failed with \(error.code)")
        }
        guard !content.isEmpty else { throw ContractViolation("the content is empty") }
        do {
            _ = try await port.content(missing)
            throw ContractViolation("missing media must throw")
        } catch let error as HaloError {
            guard error == .notFound else { throw ContractViolation("missing media must throw .notFound, got \(error.code)") }
        }
    }
}

/// Behaviour every `EncryptionPort` implementation must show. `unverified` is a port for an account that has a
/// recovery key (`recoveryKey`) but whose device hasn't used it yet.
public enum EncryptionPortContract {
    public static func verifyRecovery(_ unverified: any EncryptionPort, recoveryKey: String) async throws {
        // A wrong key is rejected as an input problem and leaves the device unverified.
        do {
            try await unverified.recover(recoveryKey: recoveryKey + "x")
            throw ContractViolation("a wrong recovery key must not verify the device")
        } catch let error as HaloError {
            guard error == .invalidInput("RECOVERY_KEY") else {
                throw ContractViolation("a wrong recovery key must throw invalidInput(RECOVERY_KEY), got \(error.code)")
            }
        }
        do { try await unverified.recover(recoveryKey: recoveryKey) } catch {
            throw ContractViolation("the right recovery key failed with \(error.code)")
        }
        for await status in unverified.statuses() {
            if status.verification == .verified { return }
            throw ContractViolation("after recovery the device must be verified, got \(status)")
        }
        throw ContractViolation("the status stream ended")
    }
}
