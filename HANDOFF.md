# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `main` · PRs #1–#51 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** **M0–M4 done** (G-FFI & G-UNREAD evaluated and recommended **pass** in [docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md), awaiting founder confirmation). **M5/M7** done except MAS container in `infra/dev` (`V-AUTH-1`, `Q-MAS-ACCOUNT`; client-side OIDC flow is implemented), Beta/Release push gateway, and 7-day AC-U8 soak. **M8 Search + Saved** and **M9 Gallery + Export** implemented. Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Codebase review ([docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md)) & outstanding issues ([docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md)):** all 22 executable review findings FIXED; all verifiable items in `OUTSTANDING_ISSUES.md` closed with tests; 5 founder decisions remain in §5.
- **Checks:** `HALO_SIM="iPhone Air" scripts/prepush.sh` passes (SwiftLint skipped: not installed/configured); `python3 -I tools/server-rules/check_server_rules.py` 16/16 `ok`; `tools/scenario-driver/run_scenarios.py` 28/28 `ok`; `ServerReadStateScenarioTests/realServerScenarios` passes; `AdapterContractTests/messageSearch` passes (`13.14s`); **physical iPhone 16 verified live (`F-DEV-1`)**.
- **CI:** PRs #1–#51 merged. Linux CI covers Foundation, Domain, TestSupport, Application; adapter, persistence, platform, features and the app are validated on Mac via `scripts/prepush.sh` (D71).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log` and [docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md) §13.
- **M8 Saved room & M9 Room Media Gallery + Export (this push on `main`):**
  - **M8 Saved room:** added `ChatCreationPort.openOrCreateSavedRoom()` (persisted in `one.mbm.halo.saved_room` account data in `MatrixChatCreationPort`, reusing an existing joined room or creating a private encrypted "Saved Messages" room once), faked in `FakeChatCreationPort`, wired into `NewChatViewModel.openSavedMessages()` / `NewChatView` ("Saved Messages" row, unit-tested in `NewChatViewModelTests.savedMessagesIdempotent`).
  - **M9 Room Media Gallery + Export:** added `RoomMediaItem` and `RoomPort.mediaGallery(in:limit:)`, implemented in `MatrixRoomPort` using `Room.timelineWithConfiguration` (`.onlyMessage([.image, .video, .audio, .file])`), faked in `FakeRoomPort`, and added `RoomDetailsViewModel.loadGallery` / `exportMediaFile` + `RoomMediaGalleryView` (segmented filter All / Photos & Videos / Files & Audio, thumbnails, ShareLink export; unit-tested in `RoomDetailsViewModelTests.roomMediaGalleryAndExport`).
- **M8 Message Search (`ade4ccb`, `V-SEARCH-1` resolved):**
  - Wired pinned SDK `Client.searchService()` behind `SearchPort`, `MatrixSearchPort`, `SearchCoordinator`, and `MessageSearchViewModel` / `MessageSearchView` (verified against `infra/dev` in `AdapterContractTests.messageSearch`).
- **M5 OIDC / OAuth 2.0 client login & M5 performance pass (`549fe8f`):**
  - Implemented OIDC/OAuth 2.0 login (`SessionPort`, `MatrixSessionPort`, `SessionCoordinator`, `WebAuthSessionPresenter`, `AuthViewModel`, `SignInView`) and M5 performance pass (`RoomListViewModel` 50-row paging, capped `Room.members()` scans).

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D82), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74:** classic Matrix sync (`syncOnceV2`, `slidingSyncVersionBuilder(.none)`) is the authoritative unread source.
- **D78 (R-01) / D79 (R-07):** SDK counts decide in encrypted rooms (`ENC_SERVER_ONLY` → no unread); E1/E1b yield to positive SDK counts once the SDK applied the read position.
- **D80 / ADR-0020 (R-06):** identity and timeline-index read ordering, `read_intent.timeline_order` (v8), `INTENT_STALE` on confirmed intents (revises D47, D72).
- **D81 (R-17):** removed native sliding-sync gate at server discovery and password login (amends AUTHENTICATION FR-5).
- **D82 / ADR-0021 (founder, supersedes D5):** app icon badge shows total unread messages across rooms needing attention (`BadgeCalculator.badge` sums `RoomReadState.badgeCount` for `attention == true`).

## 4. Modified files (this push)
- **Domain & TestSupport:** `ios/Packages/HaloDomain/Sources/HaloDomain/Ports/ChatCreationPort.swift`, `ios/Packages/HaloDomain/Sources/HaloDomain/Ports/RoomPort.swift`, `ios/Packages/HaloDomain/Sources/HaloDomain/RoomList/RoomDetails.swift`, `ios/Packages/HaloTestSupport/Sources/HaloTestSupport/FakeChatCreationPort.swift`, `ios/Packages/HaloTestSupport/Sources/HaloTestSupport/FakeRoomPort.swift`.
- **Adapter:** `ios/Packages/HaloMatrixAdapter/Sources/HaloMatrixAdapter/MatrixChatCreationPort.swift`, `ios/Packages/HaloMatrixAdapter/Sources/HaloMatrixAdapter/MatrixRoomPort.swift`.
- **Features:** `ios/Packages/Features/FeatureRoomList/Sources/FeatureRoomList/NewChatViewModel.swift`, `ios/Packages/Features/FeatureRoomList/Sources/FeatureRoomList/NewChatView.swift`, `ios/Packages/Features/FeatureRoomList/Tests/FeatureRoomListTests/NewChatViewModelTests.swift`, `ios/Packages/Features/FeatureRoomDetails/Sources/FeatureRoomDetails/RoomDetailsViewModel.swift`, `ios/Packages/Features/FeatureRoomDetails/Sources/FeatureRoomDetails/RoomDetailsView.swift`, `ios/Packages/Features/FeatureRoomDetails/Sources/FeatureRoomDetails/RoomMediaGalleryView.swift`, `ios/Packages/Features/FeatureRoomDetails/Tests/FeatureRoomDetailsTests/RoomDetailsViewModelTests.swift`.
- **Docs:** `docs/ROADMAP.md`, `HANDOFF.md`.

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
1. **M10 Threads:** thread timeline view (`TimelineFocus.thread(rootEventId:)`) and thread reply entry from timeline messages.
2. **M5 MAS compose profile** in `infra/dev` (`V-AUTH-1`, `Q-MAS-ACCOUNT`).

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
