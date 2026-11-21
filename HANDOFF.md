# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `main` · PRs #1–#51 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** **M0–M3 done** (all automated & live-device exit criteria for M3 met; G-FFI & G-UNREAD evaluated and recommended **pass** in [docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md), awaiting founder confirmation). **M4 stickers v1** done (incl. V-ST-1, V-ST-2, V-ST-3). **M5/M7** slices on `main`. Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Codebase review ([docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md)) & outstanding issues ([docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md)):** all 22 executable review findings FIXED; all verifiable items in `OUTSTANDING_ISSUES.md` closed with tests; 5 founder decisions remain in §5.
- **Checks:** `HALO_SIM="iPhone Air" scripts/prepush.sh` passes (SwiftLint skipped: not installed/configured); `python3 -I tools/server-rules/check_server_rules.py` 16/16 `ok`; `tools/scenario-driver/run_scenarios.py` 28/28 `ok`; `ServerReadStateScenarioTests/realServerScenarios` (S01–S03, S07b, S08–S20, S25–S29 end-to-end against `infra/dev`) passes; touched contracts (`stickers`, `mentionsAndEchoes`, `invitations`, `encryption`) pass; **physical iPhone 16 verified live (`F-DEV-1`)**.
- **CI:** PRs #1–#51 merged. Linux CI covers Foundation, Domain, TestSupport, Application; adapter, persistence, platform, features and the app are validated on Mac via `scripts/prepush.sh` (D71).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log` and [docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md) §13.
- **M3 real-server scenario suite S01–S29 & outstanding-issue sweep (this push on `main`):**
  - Built `ServerReadStateScenarioTests.realServerScenarios` in `HaloMatrixAdapterTests` driving the full live stack (`MatrixSessionPort`, `MatrixSyncPort`, `MatrixRoomListPort`, `MatrixRoomPort`, `MatrixReadMarkerPort`, `MatrixNotificationPort`, `HaloDatabase` `ReadIntentStore` + `NotificationRecordStore`, `RoomListCoordinator`, `ReadReceiptCoordinator`, `ReadStateCoordinator`, `NotificationProcessor`) against `infra/dev` across S01, S02, S03, S07b, S08, S09, S10, S11, S12, S13, S14, S15, S16, S17, S18, S19, S20, S25, S26, S27, S28, S29 (joining `ClassicSyncEvidenceTests` for S06/S07/S21/S23/S24 and `run_scenarios.py` for S04/S05/S22).
  - Fixed two real-server integration bugs caught by `ServerReadStateScenarioTests`:
    1. Wired `NotificationSettingsDelegate` (`PushRulesChangeDelegate`) and per-pass `client.getNotificationSettings()` in `MatrixRoomListPort` so push-rule mode changes (`m.push_rules` top-level account data, S07b/S10) immediately rebuild room summaries.
    2. Added `await root.receipts.flush()` on `.active` foreground transitions in `HaloApp` so unsent receipts restored before the initial sync finishes are flushed once the client is active and synced (S11/S20).
  - Closed verifiable items from `OUTSTANDING_ISSUES.md` & `OPEN_QUESTIONS.md`:
    - **V-ST-2 & real sticker media:** verified 401 refresh-and-retry path and real sticker image byte download (`MatrixMediaPort.content`) in `AdapterContractTests.stickers`.
    - **Raw `m.mentions` on server:** verified `m.mentions.user_ids` via Client-Server `/event` in `AdapterContractTests.mentionsAndEchoes`.
    - **Ignored-user invite `inviterID`:** verified `RoomSummary.inviterID` population on live invites in `AdapterContractTests.invitations`.
    - **Recovery key reset + self-verification:** verified `resetRecovery` + `recover(recoveryKey:)` on the creating device against `infra/dev` in `AdapterContractTests.encryption`, and added `RecoveryViewModelTests.replaceRecoveryVerifiesDevice` (updating `FakeEncryptionPort.resetRecovery` to match `F-FFI-19` `.incomplete`).
    - **Room info delayed power levels:** `RoomDetailsViewModel.load()` re-checks once after 1.5 s when initial `canEditDetails && canInvite` are false (`RoomDetailsViewModelTests.rechecksMissingPermissions`).
    - Resolved `V-NSE-1`, `V-NSE-2`, `V-NSE-3`, `V-PUSH-1`, `V-RS-1`, `V-RS-3`, `V-RS-4`, `V-RS-5`, `V-RS-6`, `V-SYNC-2`, `V-ST-2` in `docs/OPEN_QUESTIONS.md`; updated `docs/ROADMAP.md`, `docs/testing/UNREAD_REGRESSION_TESTS.md`, `docs/testing/GATE_EVALUATION_M3.md`, and pruned `docs/development/OUTSTANDING_ISSUES.md`.
- **Unread-message-count app badge (D82 / ADR-0021) & physical iPhone 16 verification (`F-DEV-1`, `F-FFI-23c`):** `BadgeCalculator.badge` sums `RoomReadState.badgeCount` across rooms needing attention; `AttentionCache` stores `[RoomID: Int]` + `updatedAt`; NSE `MatrixSessionPort` sets `enablesSlidingSync: true` (`AdapterContractTests/nseNotificationFetch`). Live-verified 10/10 APNs pushes (`6.2 MB` peak memory, `0 ms` warm restore, 10/10 GRDB records, `NSFileProtectionCompleteUntilFirstUserAuthentication`) and unread-message badge on Evan's iPhone 16.
- **Codebase review Phases 0–3 (PRs #50 & #51, `ceed637`..`ef17e53`):** 22 of 27 findings FIXED (R-01..R-13, R-15, R-17, R-19, R-20, R-22, R-23, R-25..R-27).

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D82), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74:** classic Matrix sync (`syncOnceV2`, `slidingSyncVersionBuilder(.none)`) is the authoritative unread source.
- **D78 (R-01) / D79 (R-07):** SDK counts decide in encrypted rooms (`ENC_SERVER_ONLY` → no unread); E1/E1b yield to positive SDK counts once the SDK applied the read position.
- **D80 / ADR-0020 (R-06):** identity and timeline-index read ordering, `read_intent.timeline_order` (v8), `INTENT_STALE` on confirmed intents (revises D47, D72).
- **D81 (R-17):** removed native sliding-sync gate at server discovery and password login (amends AUTHENTICATION FR-5).
- **D82 / ADR-0021 (founder, supersedes D5):** app icon badge shows total unread messages across rooms needing attention (`BadgeCalculator.badge` sums `RoomReadState.badgeCount` for `attention == true`).

## 4. Modified files (this push)
- **Adapter & App:** `ios/Packages/HaloMatrixAdapter/Sources/HaloMatrixAdapter/MatrixRoomListPort.swift`, `ios/Packages/HaloMatrixAdapter/Package.swift`, `ios/App/HaloApp.swift`, `scripts/contract-test.sh`.
- **Features & Test Support:** `ios/Packages/Features/FeatureRoomDetails/Sources/FeatureRoomDetails/RoomDetailsViewModel.swift`, `ios/Packages/Features/FeatureRoomDetails/Tests/FeatureRoomDetailsTests/RoomDetailsViewModelTests.swift`, `ios/Packages/Features/FeatureAuth/Tests/FeatureAuthTests/AuthViewModelTests.swift`, `ios/Packages/HaloTestSupport/Sources/HaloTestSupport/FakeEncryptionPort.swift`, `ios/Packages/HaloTestSupport/Sources/HaloTestSupport/FakeRoomPort.swift`.
- **Real-server scenarios & Contracts:** `ios/Packages/HaloMatrixAdapter/Tests/HaloMatrixAdapterTests/ServerReadStateScenarioTests.swift`, `ios/Packages/HaloMatrixAdapter/Tests/HaloMatrixAdapterTests/AdapterContractTests.swift`.
- **Docs:** `docs/ROADMAP.md`, `docs/OPEN_QUESTIONS.md`, `docs/testing/UNREAD_REGRESSION_TESTS.md`, `docs/testing/GATE_EVALUATION_M3.md`, `docs/development/OUTSTANDING_ISSUES.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Needs the founder**
- 👤 **Gate confirmations:** confirm **G-FFI** and **G-UNREAD** pass outcomes in [docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md) §4 (all S01–S29 automated + real-server + iPhone 16 `F-DEV-1` checks are green).
- 👤 **R-14 (filtering entitlement):** NSE delivers silent empty passive content for suppressed/no-event pushes; request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3) for complete suppression.
- 👤 **R-16 (DB field encryption):** decide whether to implement AES-GCM field encryption using `KeychainItem.haloDatabaseKey` for `draft.body` and `bot_task.title/detail`, or accept plaintext under `completeUntilFirstUserAuthentication` with a new ADR.
- 👤 **R-18 & R-21 (upstream SDK gaps):** pinned `matrix_sdk_ffi.swift` (`26.11.17`, F-FFI-23) `SyncSettingsV2` has no filter (`lazy_load_members` / timeline limit) and `Timeline` has no queued `sendRaw`/`sendSticker`; requires upstream `matrix-rust-sdk` PR + SDK pin bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide whether to build the `infra/sygnal/` Halo pushkin or amend ADR-0015, and configure the Beta/Release push gateway before TestFlight.
- 📱 **Long-horizon physical device soaks:** 100-push fault-injection G-NSE run and 7-day AC-U8 daily-driver soak.

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. Founder confirms G-FFI / G-UNREAD outcomes and resolves §5 decisions (R-14, R-16, R-18/R-21, R-24).
2. **M1/M2 remaining feature:** QR and emoji device verification (`ENCRYPTION_AND_DEVICES`).
3. **M5 MVP hardening:** MAS in `infra/dev` + OIDC login (V-AUTH-1, Q-MAS-ACCOUNT), notification tap routing (`UNUserNotificationCenterDelegate`), Settings → Storage clear cache & Diagnostics zip export (AC-U8).

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, and docs/development/OUTSTANDING_ISSUES.md.
M0–M4 and the real-server read-state scenario suite S01–S29 are complete and
verified against infra/dev and on the physical iPhone 16 (F-DEV-1).

1. If the founder has answered any of the items in HANDOFF §5 (G-FFI/G-UNREAD
   gate outcomes, R-14, R-16, R-18/R-21, R-24), implement and record those first.
2. Otherwise, pick up the next unblocked roadmap item from HANDOFF §6 /
   docs/ROADMAP.md (e.g., QR/emoji device verification or M5 MAS/OIDC /
   Settings diagnostics zip export).

Verification on this Mac:
- HALO_SIM="iPhone Air" scripts/prepush.sh
- HALO_SIM="iPhone Air" scripts/contract-test.sh <Suite/test> (infra/dev up)
- Update HANDOFF.md in the last commit before every git push (AGENTS.md §18).
```
