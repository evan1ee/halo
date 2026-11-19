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
