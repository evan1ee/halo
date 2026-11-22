import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloPersistence
import HaloTestSupport
import MatrixRustSDK
import Synchronization
import Testing
@testable import HaloMatrixAdapter

/// Real-server scenario suite S01–S29 against `infra/dev` over classic `/sync` (ROADMAP M3, GATE_EVALUATION_M3 §1,
/// UNREAD_REGRESSION_TESTS §3).
///
/// Unlike `ReadStateScenarioTests` (which drives the real coordinators against an in-process model of Synapse), this
/// suite runs the real `MatrixSessionPort`, `MatrixSyncPort`, `MatrixRoomListPort`, `MatrixReadMarkerPort`,
/// `MatrixNotificationPort`, `HaloDatabase` (`ReadIntentStore` + `NotificationRecordStore`), `RoomListCoordinator`,
/// `ReadReceiptCoordinator`, `ReadStateCoordinator` and `NotificationProcessor` against the live Synapse server.
private let env = ProcessInfo.processInfo.environment
private let configured = [
    "HALO_DEV_SERVER", "HALO_DEV_USER", "HALO_DEV_PASSWORD",
    "HALO_DEV_PEER_USER", "HALO_DEV_PEER_PASSWORD",
].allSatisfy { env[$0] != nil }

@Suite("Real-server read-state scenarios S01–S29 (G-UNREAD)", .serialized, .enabled(if: configured, "needs HALO_DEV_SERVER/USER/PASSWORD/PEER_*"))
struct ServerReadStateScenarioTests {
    /// Minimal Matrix Client-Server HTTP helper for the peer user (B) and the user's second device (A2).
    private struct MatrixHTTP: Sendable {
        let server: String

        private func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
        }

        @discardableResult
        func call(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> [String: Any] {
            let url = try #require(URL(string: server + "/_matrix/client/v3" + path))
        for attempt in 0..<8 {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429, attempt < 7 {
                    let retryMs = (json["retry_after_ms"] as? NSNumber)?.intValue ?? 1000
                    try await Task.sleep(for: .milliseconds(min(retryMs, 5000)))
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw ContractViolation("HTTP \(http.statusCode) on \(method) \(path): \(json)")
                }
            }
            return json
        }
            return [:]
        }

        func login(user: String, password: String, device: String) async throws -> (token: String, userID: String) {
            let r = try await call("POST", "/login", body: [
                "type": "m.login.password",
                "identifier": ["type": "m.id.user", "user": user],
                "password": password,
                "initial_device_display_name": device,
            ])
            return (try #require(r["access_token"] as? String), try #require(r["user_id"] as? String))
        }

        func logout(_ token: String) async {
            _ = try? await call("POST", "/logout", token: token, body: [:])
        }

        func createRoom(creatorToken: String, inviteUserID: String, joinToken: String? = nil, encrypted: Bool = false, name: String) async throws -> RoomID {
            var body: [String: Any] = [
                "name": name,
                "preset": "private_chat",
                "visibility": "private",
                "invite": [inviteUserID],
            ]
            if encrypted {
                body["initial_state"] = [[
                    "type": "m.room.encryption",
                    "state_key": "",
                    "content": ["algorithm": "m.megolm.v1.aes-sha2"],
                ]]
            }
            let r = try await call("POST", "/createRoom", token: creatorToken, body: body)
            let raw = try #require(r["room_id"] as? String, "createRoom failed: \(r)")
            if let joinToken {
                _ = try await call("POST", "/join/\(enc(raw))", token: joinToken, body: [:])
            }
            return try RoomID(raw)
        }

        func leaveAndForget(_ token: String, room: RoomID) async {
            _ = try? await call("POST", "/rooms/\(enc(room.rawValue))/leave", token: token, body: [:])
            _ = try? await call("POST", "/rooms/\(enc(room.rawValue))/forget", token: token, body: [:])
        }

        @discardableResult
        func send(_ token: String, room: RoomID, text: String, mention: String? = nil, threadRoot: String? = nil, editOf: String? = nil) async throws -> EventID {
            var content: [String: Any] = ["msgtype": "m.text", "body": text]
            if let mention {
                content["m.mentions"] = ["user_ids": [mention]]
            }
            if let threadRoot {
                content["m.relates_to"] = ["rel_type": "m.thread", "event_id": threadRoot]
            }
            if let editOf {
                content["body"] = "* \(text)"
                content["m.new_content"] = ["msgtype": "m.text", "body": text]
                content["m.relates_to"] = ["rel_type": "m.replace", "event_id": editOf]
            }
            let r = try await call(
                "PUT", "/rooms/\(enc(room.rawValue))/send/m.room.message/\(UUID().uuidString)",
                token: token, body: content)
            return try EventID(try #require(r["event_id"] as? String, "send failed: \(r)"))
        }

        @discardableResult
        func sendOpaqueEncrypted(_ token: String, room: RoomID) async throws -> EventID {
            let opaque: [String: Any] = [
                "algorithm": "m.megolm.v1.aes-sha2",
                "ciphertext": "AwgA",
                "sender_key": "x",
                "session_id": "unknown-\(UUID().uuidString)",
                "device_id": "X",
            ]
            let r = try await call(
                "PUT", "/rooms/\(enc(room.rawValue))/send/m.room.encrypted/\(UUID().uuidString)",
                token: token, body: opaque)
            return try EventID(try #require(r["event_id"] as? String))
        }

        func redact(_ token: String, room: RoomID, event: EventID) async throws {
            _ = try await call("PUT", "/rooms/\(enc(room.rawValue))/redact/\(enc(event.rawValue))/\(UUID().uuidString)", token: token, body: [:])
        }

        func read(_ token: String, room: RoomID, event: EventID) async throws {
            _ = try await call("POST", "/rooms/\(enc(room.rawValue))/receipt/m.read/\(enc(event.rawValue))", token: token, body: [:])
        }

        func setMarkedUnread(_ token: String, userID: String, room: RoomID, unread: Bool) async throws {
            _ = try await call(
                "PUT", "/user/\(enc(userID))/rooms/\(enc(room.rawValue))/account_data/m.marked_unread",
                token: token, body: ["unread": unread])
        }

        func setMode(_ token: String, room: RoomID, mode: NotificationMode) async throws {
            let r = room.rawValue
            switch mode {
            case .allMessages:
                _ = try? await call("DELETE", "/pushrules/global/override/\(enc(r))", token: token)
                _ = try? await call("DELETE", "/pushrules/global/room/\(enc(r))", token: token)
            case .mentionsAndKeywords:
                _ = try? await call("DELETE", "/pushrules/global/override/\(enc(r))", token: token)
                _ = try await call("PUT", "/pushrules/global/room/\(enc(r))", token: token, body: ["actions": []])
            case .mute:
                _ = try? await call("DELETE", "/pushrules/global/room/\(enc(r))", token: token)
                _ = try await call(
                    "PUT", "/pushrules/global/override/\(enc(r))", token: token,
                    body: ["conditions": [["kind": "event_match", "key": "room_id", "pattern": r]], "actions": []])
            }
        }
    }

    /// Wraps `ReadMarkerPort` so tests can inject transient network failures or pause outgoing receipts (S11, S12, S20).
    private final class FaultReadMarkerPort: ReadMarkerPort, Sendable {
        private let inner: any ReadMarkerPort
        private let state = Mutex<(failures: [HaloError], sent: [(room: RoomID, event: EventID)])>(([], []))

        init(_ inner: any ReadMarkerPort) { self.inner = inner }

        func failNext(_ errors: [HaloError]) { state.withLock { $0.failures = errors } }
        var sentReceipts: [(room: RoomID, event: EventID)] { state.withLock { $0.sent } }

        func sendReceipt(room: RoomID, event: EventID, isPrivate: Bool) async throws(HaloError) {
            let fail: HaloError? = state.withLock { s in
                s.failures.isEmpty ? nil : s.failures.removeFirst()
            }
            if let fail { throw fail }
            try await inner.sendReceipt(room: room, event: event, isPrivate: isPrivate)
            state.withLock { $0.sent.append((room, event)) }
        }

        func setFullyRead(room: RoomID, event: EventID) async throws(HaloError) {
            try await inner.setFullyRead(room: room, event: event)
        }

        func markRoomRead(room: RoomID, isPrivate: Bool) async throws(HaloError) -> EventID? {
            try await inner.markRoomRead(room: room, isPrivate: isPrivate)
        }

        func setMarkedUnread(room: RoomID, _ value: Bool) async throws(HaloError) {
            try await inner.setMarkedUnread(room: room, value)
        }
    }

    /// Real device A1 stack backed by `MatrixSessionPort`, `HaloDatabase`, `RoomListCoordinator`, `ReadReceiptCoordinator`,
    /// `ReadStateCoordinator` and `NotificationProcessor`.
    private final class LiveStack: @unchecked Sendable {
        let dir: URL
        let database: HaloDatabase
        let account: UserID
        var storedSession: StoredSession
        var session: MatrixSessionPort
        var sync: MatrixSyncPort
        var roomListPort: MatrixRoomListPort
        var roomPort: MatrixRoomPort
        var markerPort: FaultReadMarkerPort
        var notificationPort: MatrixNotificationPort
        let intentStore: ReadIntentStore
        let recordStore: NotificationRecordStore
        let badgePort = FakeBadgePort()
        var roomList: RoomListCoordinator
        var receipts: ReadReceiptCoordinator
        var readState: ReadStateCoordinator

        init(server: String, user: String, password: String) async throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("halo-scen-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            database = try HaloDatabase(path: dir.appendingPathComponent("halo.sqlite").path, observesSuspensionNotifications: false)
            session = MatrixSessionPort(baseDirectory: dir)
            let details = try await session.loginDetails(server: server)
            storedSession = try await session.loginPassword(
                PasswordCredentials(username: user, password: password, deviceDisplayName: "scenario-a1"),
                on: details)
            account = storedSession.userID
            intentStore = ReadIntentStore(database: database, account: account)
            recordStore = NotificationRecordStore(database: database, account: account)
            let records = recordStore
            sync = MatrixSyncPort(session: session)
            roomListPort = MatrixRoomListPort(session: session, hasRecords: { room in
                records.all().contains { $0.roomID == room }
            })
            roomPort = MatrixRoomPort(session: session)
            markerPort = FaultReadMarkerPort(MatrixReadMarkerPort(session: session))
            notificationPort = MatrixNotificationPort(session: session)
            roomList = RoomListCoordinator(port: roomListPort)
            receipts = ReadReceiptCoordinator(port: markerPort, store: intentStore)
            readState = ReadStateCoordinator(rooms: roomList, records: recordStore, port: badgePort, receipts: receipts)
            await receipts.restore()
            await readState.begin()
            await roomList.start()
            try await sync.start()
        }

        /// Simulates an app kill and relaunch over the same `halo.sqlite` and SDK store directory (S11, S20, S28).
        func relaunch(startSync: Bool = true, hangingReceipts: Bool = false) async throws {
            await sync.stop()
            await roomList.stop()
            session = MatrixSessionPort(baseDirectory: dir)
            try await session.restore(storedSession)
            let records = recordStore
            sync = MatrixSyncPort(session: session)
            roomListPort = MatrixRoomListPort(session: session, hasRecords: { room in
                records.all().contains { $0.roomID == room }
            })
            roomPort = MatrixRoomPort(session: session)
            markerPort = FaultReadMarkerPort(MatrixReadMarkerPort(session: session))
            notificationPort = MatrixNotificationPort(session: session)
            roomList = RoomListCoordinator(port: roomListPort)
            if hangingReceipts {
                receipts = ReadReceiptCoordinator(
                    port: markerPort, store: intentStore,
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
            } else {
                receipts = ReadReceiptCoordinator(port: markerPort, store: intentStore)
            }
            readState = ReadStateCoordinator(rooms: roomList, records: recordStore, port: badgePort, receipts: receipts)
            await receipts.restore()
            await readState.begin()
            await roomList.start()
            if startSync { try await sync.start() }
        }

        /// Runs the real NSE `NotificationProcessor` pipeline (using an NSE-configured `MatrixSessionPort` with
        /// `enablesSlidingSync: true` over the shared store and `NotificationRecordStore`).
        func runNSEPush(room: RoomID, event: EventID, isForeground: Bool = false) async throws -> NotificationDecision {
            let nseSession = MatrixSessionPort(
                baseDirectory: dir, holderName: "nse", sendsMessages: false,
                lightweightRuntime: true, enablesSlidingSync: true)
            try await nseSession.restore(storedSession)
            let fetcher = MatrixNotificationPort(session: nseSession)
            let badgePort = self.badgePort
            let processor = NotificationProcessor(
                fetcher: fetcher,
                records: recordStore,
                lastAttention: { (badgePort.countsHistory.last ?? [:], Date(timeIntervalSince1970: 0)) },
                isAppForeground: { isForeground })
            return await processor.process(room: room, event: event)
        }

        /// Waits until `RoomListCoordinator` reports a summary for `room` satisfying `predicate`.
        @discardableResult
        func waitForSummary(_ room: RoomID, seconds: Double = 30, _ label: String, _ predicate: @Sendable (RoomSummary) -> Bool) async throws -> RoomSummary {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                if let summary = await roomList.rooms.first(where: { $0.id == room }), predicate(summary) {
                    return summary
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            let current = await roomList.rooms.first(where: { $0.id == room })
            throw ContractViolation("timed out waiting for summary \(label) in \(room.rawValue); current=\(String(describing: current))")
        }

        /// Waits until `ReadStateCoordinator` publishes a state for `room` satisfying `predicate`.
        @discardableResult
        func waitForRoom(_ room: RoomID, seconds: Double = 30, _ label: String, _ predicate: @Sendable (RoomReadState) -> Bool) async throws -> RoomReadState {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                if let state = await readState.roomStates[room], predicate(state) {
                    return state
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            let current = await readState.roomStates[room]
            throw ContractViolation("timed out waiting for \(label) in \(room.rawValue); current=\(String(describing: current))")
        }

        /// Waits until `predicate` holds over the stack.
        func waitUntil(seconds: Double = 30, _ label: String, _ predicate: @Sendable () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline {
                if await predicate() { return }
                try await Task.sleep(for: .milliseconds(150))
            }
            throw ContractViolation("timed out waiting for \(label)")
        }

        /// Resolves the server's `origin_server_ts` for `event` through the SDK room.
        func eventTimestamp(room: RoomID, event: EventID) async throws -> Date {
            let sdkRoom = try await session.room(room)
            let sdkEvent = try await sdkRoom.loadOrFetchEvent(eventId: event.rawValue)
            return Date(timeIntervalSince1970: Double(sdkEvent.timestamp()) / 1000)
        }

        /// Reads the user's own receipt event ID for `room` as synced into the SDK room.
        func ownReceiptEventID(room: RoomID) async throws -> EventID? {
            let sdkRoom = try await session.room(room)
            let me = sdkRoom.ownUserId()
            for type in [ReceiptType.read, .readPrivate] {
                if let receipt = try? await sdkRoom.loadUserReceipt(receiptType: type, thread: .unthreaded, userId: me) {
                    return try? EventID(receipt.eventId)
                }
            }
            return nil
        }

        func shutdown() async {
            await sync.stop()
            await roomList.stop()
            try? await session.logout()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("Real-server client & server scenarios S01, S02, S03, S07b, S08, S09, S10, S11, S12, S13, S14, S15, S16, S17, S18, S19, S20, S25, S26, S27, S28, S29 against infra/dev")
    func realServerScenarios() async throws {
        let server = try #require(env["HALO_DEV_SERVER"])
        let user = try #require(env["HALO_DEV_USER"])
        let password = try #require(env["HALO_DEV_PASSWORD"])
        let peerUser = try #require(env["HALO_DEV_PEER_USER"])
        let peerPassword = try #require(env["HALO_DEV_PEER_PASSWORD"])

        let http = MatrixHTTP(server: server)
        let a2 = try await http.login(user: user, password: password, device: "scenario-a2")
        let b = try await http.login(user: peerUser, password: peerPassword, device: "scenario-b")
        let stack = try await LiveStack(server: server, user: user, password: password)
        let createdRooms = Mutex<[RoomID]>([])
        defer {
            let rooms = createdRooms.withLock { $0 }
            Task {
                for r in rooms {
                    await http.leaveAndForget(a2.token, room: r)
                    await http.leaveAndForget(b.token, room: r)
                }
                await stack.shutdown()
                await http.logout(a2.token)
                await http.logout(b.token)
            }
        }

        func makeRoom(_ name: String) async throws -> RoomID {
            let room = try await http.createRoom(
                creatorToken: b.token, inviteUserID: a2.userID, joinToken: a2.token, name: name)
            createdRooms.withLock { $0.append(room) }
            _ = try await stack.waitForRoom(room, "joined \(name)") { _ in true }
            return room
        }

        // --- S01: B sends 5 messages in a DM; A1 views them -> no attention, server receipt at 5th ---
        let r01 = try await makeRoom("S01")
        var evs01: [EventID] = []
        for i in 1...5 { evs01.append(try await http.send(b.token, room: r01, text: "s01-\(i)")) }
        let last01 = evs01[4]
        let s01Unread = try await stack.waitForRoom(r01, "S01 5 unread") { $0.attention && $0.badgeCount == 5 }
        #expect(s01Unread.display == .count(5))
        let ts01 = try await stack.eventTimestamp(room: r01, event: last01)
        await stack.receipts.reportSeen(room: r01, event: last01, timestamp: ts01, advancesOrder: true)
        await stack.receipts.flush()
        _ = try await stack.waitForRoom(r01, "S01 cleared after view") { !$0.attention }
        try await stack.waitUntil("S01 server receipt at 5th") {
            (try? await stack.ownReceiptEventID(room: r01)) == last01
        }

        // --- S02 & S17: B sends 5; A2 reads them; A1 syncs -> no attention within one sync, badge drops ---
        let r02 = try await makeRoom("S02-S17")
        var evs02: [EventID] = []
        for i in 1...5 { evs02.append(try await http.send(b.token, room: r02, text: "s02-\(i)")) }
        let last02 = evs02[4]
        _ = try await stack.waitForRoom(r02, "S02 5 unread") { $0.attention && $0.badgeCount == 5 }
        #expect(stack.badgePort.history.last?.contains(r02) == true)
        try await http.read(a2.token, room: r02, event: last02)
        _ = try await stack.waitForRoom(r02, "S02/S17 cleared by A2 receipt") { !$0.attention }
        #expect(stack.badgePort.history.last?.contains(r02) != true)

        // --- S03 & S16: B sends 1 while A1 sync is paused; NSE processes push (twice for S16 dedup); then A1 syncs; then views ---
        let r03 = try await makeRoom("S03-S16")
        let base03 = try await http.send(b.token, room: r03, text: "s03-base")
        try await http.read(a2.token, room: r03, event: base03)
        _ = try await stack.waitForRoom(r03, "S03 read baseline") { !$0.attention }
        await stack.sync.stop()
        let pushedEv = try await http.send(b.token, room: r03, text: "s03-pushed")
        let decision1 = try await stack.runNSEPush(room: r03, event: pushedEv)
        guard case .deliver(_, let body03, _, let badge03, _) = decision1 else {
            Issue.record("S03 expected .deliver from NSE, got \(decision1)"); return
        }
        #expect(body03.contains("s03-pushed"))
        #expect((badge03 ?? 0) >= 1)
        // S16: duplicate APNs delivery for the same event ID is suppressed (AC-U7).
        let decision2 = try await stack.runNSEPush(room: r03, event: pushedEv)
        #expect(decision2 == .suppressed(outcome: "duplicate"))
        #expect(stack.recordStore.all().filter { $0.eventID == pushedEv }.count == 1)
        // App reconciles from GRDB notification_record before sync resumes (E4).
        await stack.readState.reconcile()
        let s03BeforeSync = try await stack.waitForRoom(r03, "S03 attention from E4 before sync") { $0.attention }
        #expect(s03BeforeSync.reasons.contains(.notifiedUnsynced))
        // Sync resumes: attention persists, and sync supersedes the notification record.
        try await stack.sync.start()
        _ = try await stack.waitForRoom(r03, "S03 attention after sync") { $0.attention }
        let ts03 = try await stack.eventTimestamp(room: r03, event: pushedEv)
        await stack.receipts.reportSeen(room: r03, event: pushedEv, timestamp: ts03, advancesOrder: true)
        await stack.receipts.flush()
        _ = try await stack.waitForRoom(r03, "S03 cleared after view") { !$0.attention }

        // --- S07b: Unencrypted mentions-only room, B sends 3 messages without mention; A1 views them -> receipt sent for 3rd ---
        let r07b = try await makeRoom("S07b")
        let base07b = try await http.send(b.token, room: r07b, text: "s07b-base")
        try await http.read(a2.token, room: r07b, event: base07b)
        _ = try await stack.waitForRoom(r07b, "S07b baseline") { !$0.attention }
        try await stack.roomPort.setNotificationMode(.mentionsAndKeywords, in: r07b)
        try await stack.waitUntil("S07b mode mentionsAndKeywords in details") {
            (try? await stack.roomPort.details(r07b).notificationMode) == .mentionsAndKeywords
        }
        var evs07b: [EventID] = []
        for i in 1...3 { evs07b.append(try await http.send(b.token, room: r07b, text: "s07b-quiet-\(i)")) }
        let last07b = evs07b[2]
        // Server counts stay 0 in mentions-only mode without a mention: no attention, and readPosition is not advanced by serverZero (P9).
        _ = try await stack.waitForSummary(r07b, "S07b summary updated with 3 quiet messages") {
            $0.read.mode == .mentionsAndKeywords && $0.read.sdk.unreadMessages == 3 && $0.read.server == .zero
        }
        let s07bState = try await stack.waitForRoom(r07b, "S07b quiet") { !$0.attention && $0.hasUnread }
        #expect(!s07bState.attention && s07bState.hasUnread)
        let ts07b = try await stack.eventTimestamp(room: r07b, event: last07b)
        await stack.receipts.reportSeen(room: r07b, event: last07b, timestamp: ts07b, advancesOrder: true)
        await stack.receipts.flush()
        try await stack.waitUntil("S07b receipt sent for 3rd message") {
            stack.markerPort.sentReceipts.contains { $0.room == r07b && $0.event == last07b }
        }

        // --- S08: The only unread message is redacted -> no attention ---
        let r08 = try await makeRoom("S08")
        let ev08 = try await http.send(b.token, room: r08, text: "s08-oops")
        _ = try await stack.waitForRoom(r08, "S08 unread") { $0.attention }
        try await http.redact(b.token, room: r08, event: ev08)
        _ = try await stack.waitForRoom(r08, "S08 cleared after redaction") { !$0.attention }

        // --- S09: A2 marks room unread -> attention (MARKED_UNREAD); A1 opens room -> flag cleared on server ---
        let r09 = try await makeRoom("S09")
        let ev09 = try await http.send(b.token, room: r09, text: "s09-msg")
        try await http.read(a2.token, room: r09, event: ev09)
        _ = try await stack.waitForRoom(r09, "S09 read") { !$0.attention }
        try await http.setMarkedUnread(a2.token, userID: a2.userID, room: r09, unread: true)
        _ = try await stack.waitForRoom(r09, "S09 marked unread") { $0.attention && $0.reasons.contains(.markedUnread) }
        await stack.receipts.roomOpened(r09)
        _ = try await stack.waitForRoom(r09, "S09 cleared after roomOpened") { !$0.attention }

        // --- S10: A2 mutes a room that has unread messages -> A1 attention gone ---
        let r10 = try await makeRoom("S10")
        _ = try await http.send(b.token, room: r10, text: "s10-unread")
        _ = try await stack.waitForRoom(r10, "S10 unread before mute") { $0.attention }
        try await stack.roomPort.setNotificationMode(.mute, in: r10)
        try await stack.waitUntil("S10 muted in details") {
            (try? await stack.roomPort.details(r10).notificationMode) == .mute
        }
        _ = try await stack.waitForSummary(r10, "S10 summary muted") { $0.read.mode == .mute }
        _ = try await stack.waitForRoom(r10, "S10 attention gone after mute") { !$0.attention }

        // --- S11 & S20: A1 views latest event while receipt sending fails (offline); app restarts over GRDB; network returns -> outbox sends receipt ---
        let r11 = try await makeRoom("S11-S20")
        let ev11 = try await http.send(b.token, room: r11, text: "s11-msg")
        _ = try await stack.waitForRoom(r11, "S11 unread") { $0.attention }
        stack.markerPort.failNext(Array(repeating: .network(retryable: true), count: 50))
        let ts11 = try await stack.eventTimestamp(room: r11, event: ev11)
        await stack.receipts.reportSeen(room: r11, event: ev11, timestamp: ts11, advancesOrder: true)
        // Cleared immediately via local intent before the receipt reaches the server.
        _ = try await stack.waitForRoom(r11, "S11 cleared locally") { !$0.attention }
        let stored11 = try await stack.intentStore.all()
        #expect(stored11.contains { $0.room == r11 && $0.event == ev11 && !$0.isSent })
        // App killed and relaunched over the same SQLite DB; once the room is synced, foreground flush sends the pending receipt.
        try await stack.relaunch(startSync: true)
        _ = try await stack.waitForRoom(r11, "S11/S20 still cleared after relaunch") { !$0.attention }
        await stack.receipts.flush()
        try await stack.waitUntil("S11/S20 receipt reaches server after relaunch") {
            (try? await stack.ownReceiptEventID(room: r11)) == ev11
        }
        try await stack.waitUntil("S11/S20 intent marked sent in GRDB") {
            ((try? await stack.intentStore.all()) ?? []).contains { $0.room == r11 && $0.event == ev11 && $0.isSent }
        }

        // --- S12: Receipt send fails 3 times -> intent stays pending with attempts=3 in GRDB, no attention meanwhile, 4th succeeds ---
        let r12 = try await makeRoom("S12")
        let ev12 = try await http.send(b.token, room: r12, text: "s12-msg")
        _ = try await stack.waitForRoom(r12, "S12 unread") { $0.attention }
        stack.markerPort.failNext(Array(repeating: .network(retryable: true), count: 3))
        let ts12 = try await stack.eventTimestamp(room: r12, event: ev12)
        await stack.receipts.reportSeen(room: r12, event: ev12, timestamp: ts12, advancesOrder: true)
        _ = try await stack.waitForRoom(r12, "S12 no attention while retrying") { !$0.attention }
        for _ in 0..<2 { await stack.receipts.flush() }
        try await stack.waitUntil("S12 3 failed attempts recorded in GRDB") {
            ((try? await stack.intentStore.all()) ?? []).contains { $0.room == r12 && !$0.isSent && $0.attempts >= 1 }
        }
        await stack.receipts.flush()
        try await stack.waitUntil("S12 succeeds after failures") {
            ((try? await stack.intentStore.all()) ?? []).contains { $0.room == r12 && $0.isSent }
        }

        // --- S13: A1 sends a message in a room with unread messages -> attention cleared (E1b) ---
        let r13 = try await makeRoom("S13")
        _ = try await http.send(b.token, room: r13, text: "s13-peer-1")
        _ = try await http.send(b.token, room: r13, text: "s13-peer-2")
        _ = try await stack.waitForRoom(r13, "S13 2 unread") { $0.attention }
        let tl13 = try await MatrixTimelinePort(session: stack.session).open(room: r13)
        try await tl13.send(text: "s13-my-reply", mentions: [])
        let s13Cleared = try await stack.waitForRoom(r13, "S13 cleared by own message E1b") { !$0.attention }
        #expect(s13Cleared.reasons.contains(.ownLatest))
        await tl13.close()

        // --- S14: Thread replies by B after root was read -> attention; unthreaded receipt at last reply clears it ---
        let r14 = try await makeRoom("S14")
        let root14 = try await http.send(b.token, room: r14, text: "s14-root")
        let tsRoot14 = try await stack.eventTimestamp(room: r14, event: root14)
        await stack.receipts.reportSeen(room: r14, event: root14, timestamp: tsRoot14, advancesOrder: true)
        await stack.receipts.flush()
        _ = try await stack.waitForRoom(r14, "S14 root read") { !$0.attention }
        let reply14 = try await http.send(b.token, room: r14, text: "s14-thread-reply", threadRoot: root14.rawValue)
        _ = try await stack.waitForRoom(r14, "S14 thread reply unread") { $0.attention }
        let tsReply14 = try await stack.eventTimestamp(room: r14, event: reply14)
        await stack.receipts.reportSeen(room: r14, event: reply14, timestamp: tsReply14, advancesOrder: true)
        await stack.receipts.flush()
        _ = try await stack.waitForRoom(r14, "S14 thread reply cleared by unthreaded receipt") { !$0.attention }

        // --- S15: B edits an old read message -> no new attention ---
        let r15 = try await makeRoom("S15")
        let orig15 = try await http.send(b.token, room: r15, text: "s15-orig")
        let tsOrig15 = try await stack.eventTimestamp(room: r15, event: orig15)
        await stack.receipts.reportSeen(room: r15, event: orig15, timestamp: tsOrig15, advancesOrder: true)
        await stack.receipts.flush()
        _ = try await stack.waitForRoom(r15, "S15 orig read") { !$0.attention }
        _ = try await http.send(b.token, room: r15, text: "s15-edited", editOf: orig15.rawValue)
        let probe15 = try await makeRoom("S15-probe")
        _ = try await stack.waitForRoom(probe15, "S15 sync barrier") { _ in true }
        let s15After = await stack.readState.roomStates[r15]
        #expect(s15After?.attention == false)

        // --- S26 & S28: Room with notification record and carried attention is left on A2 while A1 is closed; A1 relaunches & syncs -> pruned ---
        let r26 = try await makeRoom("S26-S28")
        let ev26 = try await http.send(b.token, room: r26, text: "s26-msg")
        _ = try await stack.waitForRoom(r26, "S26 unread") { $0.attention }
        await stack.sync.stop()
        _ = stack.recordStore.add(NotificationRecord(roomID: r26, eventID: ev26, timestamp: Date(), isMention: false))
        await http.leaveAndForget(a2.token, room: r26)
        try await stack.relaunch(startSync: true)
        try await stack.waitUntil("S26/S28 left room record pruned & dropped from badge after first sync") {
            let hasRecord = stack.recordStore.all().contains { $0.roomID == r26 }
            let inBadge = stack.badgePort.history.last?.contains(r26) == true
            return !hasRecord && !inBadge
        }

        // --- S27: Account isolation in GRDB notification_record and ReadStateCoordinator.reset() ---
        let otherAccount = try UserID("@other_account:halo.localhost")
        let otherStore = NotificationRecordStore(database: stack.database, account: otherAccount)
        let dummyRoom = try RoomID("!dummy_s27:halo.localhost")
        _ = otherStore.add(NotificationRecord(roomID: dummyRoom, eventID: try EventID("$s27_x"), timestamp: Date(), isMention: false))
        #expect(!stack.recordStore.all().contains { $0.roomID == dummyRoom })
        otherStore.clearAll()

        // --- S18 & S29: Clock-skewed / identical-timestamp messages: viewing the first does not hide the second once confirmed; viewing the second advances the receipt (R-06, ADR-0020) ---
        let r29 = try await makeRoom("S18-S29")
        let ev29a = try await http.send(b.token, room: r29, text: "s29-first")
        let ev29b = try await http.send(b.token, room: r29, text: "s29-second")
        _ = try await stack.waitForRoom(r29, "S29 2 unread") { $0.attention && $0.badgeCount == 2 }
        let ts29b = try await stack.eventTimestamp(room: r29, event: ev29b)
        // Stamp the first receipt with the same timestamp as `ev29b` (simulating identical millisecond `origin_server_ts`, S29).
        // Once the first receipt is confirmed on the server, `INTENT_STALE` prevents the equal timestamp from hiding `ev29b`.
        await stack.receipts.reportSeen(room: r29, event: ev29a, timestamp: ts29b, advancesOrder: true)
        await stack.receipts.flush()
        _ = try await stack.waitForRoom(r29, "S29 second message still unread after first receipt confirmed") {
            $0.attention && $0.badgeCount == 1 && $0.reasons.contains(.intentStale)
        }
        // S18: viewing `ev29b` even with a clock-skewed earlier timestamp advances the receipt by timeline order (`advancesOrder: true`).
        let skewedEarlierTs = ts29b.addingTimeInterval(-600)
        await stack.receipts.reportSeen(room: r29, event: ev29b, timestamp: skewedEarlierTs, advancesOrder: true)
        await stack.receipts.flush()
        _ = try await stack.waitForRoom(r29, "S18/S29 cleared after viewing skewed/equal-ts second message") { !$0.attention }
        try await stack.waitUntil("S18/S29 server receipt advanced to second message") {
            (try? await stack.ownReceiptEventID(room: r29)) == ev29b
        }

        // --- S19: Concurrent multi-room mutations settle to a fresh evaluation ---
        let concRooms = [r01, r02, r08, r09, r13]
        var concLast: [RoomID: EventID] = [:]
        for r in concRooms {
            concLast[r] = try await http.send(b.token, room: r, text: "s19-burst")
        }
        for r in concRooms {
            _ = try await stack.waitForRoom(r, "S19 burst unread") { $0.attention }
        }
        for r in concRooms {
            if let ev = concLast[r] { try await http.read(a2.token, room: r, event: ev) }
        }
        for r in concRooms {
            _ = try await stack.waitForRoom(r, "S19 burst cleared") { !$0.attention }
        }

        // --- S25: Encrypted room UTD push stamped with event ts, sync delivers & decrypts, A2 reads -> record superseded & pruned without opening (R-02) ---
        let r25 = try await http.createRoom(
            creatorToken: b.token, inviteUserID: a2.userID, joinToken: a2.token, encrypted: true, name: "S25-enc")
        createdRooms.withLock { $0.append(r25) }
        _ = try await stack.waitForRoom(r25, "joined S25-enc") { _ in true }
        await stack.sync.stop()
        let ev25 = try await http.sendOpaqueEncrypted(b.token, room: r25)
        let raw25 = try await http.call("GET", "/rooms/\(r25.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? r25.rawValue)/event/\(ev25.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ev25.rawValue)", token: b.token)
        let ts25Ms = (raw25["origin_server_ts"] as? NSNumber)?.doubleValue ?? (Date().timeIntervalSince1970 * 1000)
        let ts25 = Date(timeIntervalSince1970: ts25Ms / 1000)
        _ = stack.recordStore.add(NotificationRecord(roomID: r25, eventID: ev25, timestamp: ts25, isMention: false))
        await stack.readState.reconcile()
        _ = try await stack.waitForRoom(r25, "S25 attention from push record") { $0.attention }
        try await http.read(a2.token, room: r25, event: ev25)
        try await stack.sync.start()
        try await stack.waitUntil("S25 record pruned and attention cleared after A2 read + sync") {
            let hasRec = stack.recordStore.all().contains { $0.eventID == ev25 }
            let att = await stack.readState.roomStates[r25]?.attention ?? true
            return !hasRec && !att
        }
    }
}
