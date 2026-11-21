# Halo — Session Handoff

Last updated: 2026-11-21 · Branch: `main` · PRs #1–#51 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** M0–M2 done; **M3 (read-state engine)** hardened across all 27 findings of [docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md) (22 **FIXED**, 5 **Needs founder** in §5). Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Codebase review (2026-11-21):** **Complete.** All 7 P0s FIXED (R-01 D78, R-02/R-03/R-13, R-04, R-05/R-08 PR #50, R-06 D80/ADR-0020 PR #51, R-07 D79); Phase 0.6–0.7 FIXED (R-10, R-12, R-09); Phase 1 FIXED (R-11, R-15, §12 docs realignment; R-14 silent delivery done, entitlement Needs founder; R-16 Needs founder); Phase 2 FIXED (R-17 D81, R-19, R-20, R-22, R-23, R-25; R-18/R-21 Needs founder upstream SDK); Phase 3 & hygiene FIXED (R-26 deterministic suite + `MediaPortContract` fixture fix, R-27; R-24 Needs founder).
- **Checks:** `HALO_SIM="iPhone Air" scripts/prepush.sh` passes (SwiftLint skipped: not installed/configured); `python3 -I tools/server-rules/check_server_rules.py` 16/16 `ok`; touched `infra/dev` contracts (`session`, `remoteLogoutDuringSync`, `nseNotificationFetch`, `roomList`, `policyOverRealInputs`, `readMarkers`, `timeline`, `mentionsAndEchoes`, `media`) all pass; **physical iPhone 16 verified live (`F-DEV-1`)**.
- **CI:** PRs #1–#51 merged. Linux CI covers Foundation, Domain, TestSupport, Application; adapter, persistence, platform, features and the app are validated on Mac via `scripts/prepush.sh` (D71).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log` and [docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md) §13.
- **Physical iPhone 16 verification & NSE sliding-sync fix (`F-DEV-1`, `F-FFI-23c`):** caught and fixed a post-D74 regression where `NotificationClient.getNotification` failed in 0–2 ms when `MatrixSessionPort` hardcoded `slidingSyncVersion: .none`; added `enablesSlidingSync: true` for the NSE (`AdapterContractTests/nseNotificationFetch`) and `#if DEBUG` storage diagnostics in `AppRoot`. Verified on Evan's iPhone 16 against `infra/dev` + Sygnal APNs sandbox: 10/10 pushes `outcome: "display"`, peak `footprintMB = 6.2 MB` (R-09), cold `restoreMs = 157 ms` / warm `restoreMs = 0 ms` (`totalMs = 44–96 ms`, R-23), `notificationRecordsAtLaunch = 10` in GRDB (R-13), `NSFileProtectionCompleteUntilFirstUserAuthentication` on `halo.sqlite`/`-wal`/`-shm`/dir (SQLite 3.54.0), 0 crashes / 0 `0xdead10cc` (R-25).
- **Codebase review Phases 0.6–3 (this push on `main`):**
  - **R-10 + R-12:** `Client.setDelegate` (`AuthDelegate`) + `runSync` `.unauthorized` stop sync and emit `.loggedOut`/`.softLoggedOut` (PS34 + `AdapterContractTests/remoteLogoutDuringSync`); single-flight restore + generation guard in `SessionCoordinator` and `MatrixSessionPort` (PS35).
  - **R-09:** forwarded `lightweightRuntime` through `MatrixSessionPort.restore` and `loginPassword`; added `MatrixBootstrapTests` (verifies `sentryConfig == nil`).
  - **R-11:** synchronous `KeychainStore.readSync`/`writeSync`; seeded `RefreshDelegate` + shared Keychain read/write so NSE persists rotated refresh tokens immediately (`RefreshDelegateTests`).
  - **R-14 + R-15:** NSE delivers silent empty passive content for `.suppressed`/`no-event` (ready for filtering entitlement); removed blanket `records.clear(room:)` from `TimelineCoordinator.open()` and added identity record pruning (`BadgeCoordinatorTests.openKeepsUntilSeen`).
  - **§12 docs realignment:** updated `SYNC_ENGINE.md`, `SDK_INTEGRATION.md`, `UNREAD_STATE.md`, `READ_RECEIPTS.md`, `ADR-0015` status.
  - **R-17, R-19, R-20, R-22, R-23, R-25:** removed stale sliding-sync login gate (D81); single `roomInfo()` + bounded parallel rebuilds (max 8) in `MatrixRoomListPort`; `MatrixReadMarkerPort.markRoomRead` uses `Room.markAsRead`; wrapped background receipt flush in `BackgroundTaskLease` (`beginBackgroundTask`); cached one restored NSE `Client` + DB per `(userID, deviceID)` via `SingleFlightCache`; enabled GRDB `observesSuspensionNotifications` + `HaloDatabase.suspendAll()`/`resumeAll()` on background/active (`HaloDatabaseTests.suspendsAndResumes`).
  - **R-26 + R-27:** awaited `ReadReceiptCoordinator.persist` before `reportSeen` returns (PS36); fixed pre-existing `MediaPortContract` (`blue.png` lookup); rotated `nse-metrics.jsonl` at 128 KB; bounded instance-scoped `EventTimeCache`; `ErrorMapper.mapLocalEcho`; locked `RoomListCoordinator.start()` to `.all`.
- **PR #51 (R-06, D80 / ADR-0020):** `TimelineReadTracker` index-ordered receipts + tail `latestEventId()`, `read_intent.timeline_order` (v8), identity E1 + `INTENT_STALE`, S18 inverted & S29.
- **PR #50 + earlier Phase 0 (R-02, R-03, R-04, R-05, R-08, R-13):** GRDB `notification_record` (v7) + `DarwinSignal`, raw event timestamps, left/hidden/ignored/sign-out pruning, `syncCompletions()` carry-over termination, unified `ReadStateCoordinator`, `NotificationProcessor` in `HaloApplication`, S25–S28, PS31–PS33.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D81), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74:** classic Matrix sync (`syncOnceV2`, `slidingSyncVersionBuilder(.none)`) is the authoritative unread source.
- **D78 (R-01) / D79 (R-07):** SDK counts decide in encrypted rooms (`ENC_SERVER_ONLY` → no unread); E1/E1b yield to positive SDK counts once the SDK applied the read position.
- **D80 / ADR-0020 (R-06):** identity and timeline-index read ordering, `read_intent.timeline_order` (v8), `INTENT_STALE` on confirmed intents (revises D47, D72).
- **D81 (R-17):** removed native sliding-sync gate at server discovery and password login (amends AUTHENTICATION FR-5).
- **D82 / ADR-0021 (founder, supersedes D5):** app icon badge shows total unread messages across rooms needing attention (`BadgeCalculator.badge` sums `RoomReadState.badgeCount` for `attention == true`; `AttentionCache` stores `[RoomID: Int]` + `updatedAt` so the NSE recomputes from GRDB `notification_record` without raw increments).

## 4. Modified files (this push)
- **Unread-message-count app badge (D82 / ADR-0021):** `HaloDomain` (`ReadState.swift`, `BadgePort.swift`, `ReadStatePolicyTests.swift`), `HaloTestSupport` (`FakeBadgePort.swift`), `HaloPlatform` (`SystemBadge.swift`, `AttentionCacheTests.swift`), `HaloApplication` (`ReadStateCoordinator.swift`, `NotificationProcessor.swift`, `BadgeCoordinatorTests.swift`, `NotificationProcessorTests.swift`), `ios/NotificationService/NotificationService.swift`, `docs/adr/0021-unread-message-count-badge.md`, `docs/adr/README.md`, `docs/DECISION_LOG.md`, `docs/matrix/UNREAD_STATE.md`, `HANDOFF.md`.

## 5. Outstanding issues
Unverified items and known limits: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).
- **Prepush on this Mac:** default simulator `iPhone 17` is not installed; run `HALO_SIM="iPhone Air" scripts/prepush.sh`.

**Needs the founder** (all codebase review decisions & physical-device checks)
- 👤 **R-14 (filtering entitlement):** NSE now delivers silent empty passive content for suppressed/no-event pushes; request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3) for complete suppression.
- 👤 **R-16 (DB field encryption):** decide whether to implement AES-GCM field encryption using `KeychainItem.haloDatabaseKey` for `draft.body` and `bot_task.title/detail`, or accept plaintext under `completeUntilFirstUserAuthentication` with a new ADR.
- 👤 **R-18 (classic-sync filter / lazy-load members):** pinned `matrix_sdk_ffi.swift` (`26.11.17`, F-FFI-23) `SyncSettingsV2` exposes only `timeoutMs` and `fullState`; requires an upstream `matrix-rust-sdk` PR + SDK pin bump.
- 👤 **R-21 (queued sticker sending):** pinned `matrix_sdk_ffi.swift` (`26.11.17`, F-FFI-23) `Timeline` has no `sendRaw`/`sendSticker` API (`Room.sendRaw` is the only option); requires an upstream `matrix-rust-sdk` PR + SDK pin bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide whether to build the `infra/sygnal/` Halo pushkin or amend ADR-0015, and configure the Beta/Release push gateway before TestFlight.
- 📱 **Remaining physical device checks:** full 100-push AC-NSE-1…6 fault-injection run (timeouts, mid-step extension kill, network faults), 7-day AC-U8 soak / background `0xdead10cc` soak, and V-RS-1. *(Verified on iPhone 16 `F-DEV-1`: R-09 6.2 MB peak memory, R-23 0 ms warm restore / 44–96 ms total, R-13 10/10 GRDB records, `NSFileProtectionCompleteUntilFirstUserAuthentication` on `halo.sqlite`/`-wal`/`-shm`/dir, 0 crashes.)*
- 👤 **Gate outcomes:** G-FFI / G-UNREAD ([docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md)); real-server scenario driver for S01–S29 remains on ROADMAP M3; Mac CI deferred (D71).

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. Founder resolves §5 decisions (R-16 field encryption vs ADR; R-24 pushkin + push gateway; R-14 filtering entitlement; R-18/R-21 upstream SDK priorities) and runs 📱 checks.
2. **Real-server scenario driver (M3 / G-UNREAD):** build `tools/scenario-driver` to run S01–S29 against Synapse with two real SDK clients (closes the remaining structural part of R-26).
3. **Product & M5/M7 candidates:** notification tap routing (`UNUserNotificationCenterDelegate`), M5 MAS + OIDC login (enables live refresh-token contract test for R-11), SAS/QR verification, opt-in diagnostics export, M7 Bot Activity reaction menu (FR-4).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, and docs/CODEBASE_REVIEW.md §13. All 27 review
findings are now resolved (22 FIXED, 5 Needs founder in HANDOFF §5).

If the founder answered any of R-14, R-16, R-18, R-21, or R-24, implement the
chosen decision first (with tests, ADR/Dnn where applicable, and updated docs).
Otherwise, pick up the next unblocked milestone item from HANDOFF §6 /
docs/ROADMAP.md (e.g., M3 real-server scenario driver for G-UNREAD or M5/M7).

Verification on this Mac:
- HALO_SIM="iPhone Air" scripts/prepush.sh
- HALO_SIM="iPhone Air" scripts/contract-test.sh <Suite/test> (infra/dev up)
- python3 -I tools/server-rules/check_server_rules.py
- Update HANDOFF.md in the last commit before every git push (AGENTS.md §18).
```
