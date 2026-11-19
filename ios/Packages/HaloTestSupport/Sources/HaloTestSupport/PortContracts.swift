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
