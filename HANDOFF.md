# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `main` · PRs #1–#51 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** **Complete for all unblocked items (M0–M10 done).** Every item in [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work" that can be executed without the founder or long-horizon physical-device soaks is implemented and verified. Remaining items wait on the founder or physical-device soaks in §5 ([docs/development/AUTONOMOUS_LOOP.md](docs/development/AUTONOMOUS_LOOP.md) §4).
- **Milestones:** M0–M4, M6–M10 done (G-FFI & G-UNREAD evaluated and recommended **pass** in [docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md), awaiting founder confirmation); M5 done except Beta/Release push gateway + TestFlight and the 7-day AC-U8 soak. Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Codebase review ([docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md)) & outstanding issues ([docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md)):** all 22 executable review findings FIXED; all verifiable items closed with tests; 5 founder decisions remain in §5.
- **Checks:** `HALO_SIM="iPhone Air" scripts/prepush.sh` passes (SwiftLint skipped: not installed/configured); `python3 -I tools/server-rules/check_server_rules.py` 16/16 `ok`; `tools/scenario-driver/run_scenarios.py` 28/28 `ok`; `ServerReadStateScenarioTests/realServerScenarios` passes; `AdapterContractTests/messageSearch` passes (`13.14s`); `infra/dev/smoke-mas.sh` + `AdapterContractTests/oidcDiscovery` pass (`0.821s`); **physical iPhone 16 verified live (`F-DEV-1`, `F-DEV-2`: 100/100 G-NSE soak, peak 7.40 MB, p95 144 ms, fault-injection + post-kill cold-start recovery)**.
- **CI:** PRs #1–#51 merged. Linux CI covers Foundation, Domain, TestSupport, Application; adapter, persistence, platform, features and the app are validated on Mac via `scripts/prepush.sh` (D71).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log` and [docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md) §13.
- **Sticker send UX/validation & multi-image sending (this push on `main`):**
  - Sanitised `MatrixTimelinePort.stickerContent` (non-empty `body`, positive `w`/`h`/`size`), added `StickerPanelViewModel.isSending` double-tap guard, auto-dismissed `StickerPanelView` when a sticker sends (including after the one-time encryption notice), surfaced the error code on failure, and verified both unencrypted and encrypted-room sticker sends in `AdapterContractTests.stickers` (`17.38s`).
  - Upgraded `TimelineViewModel` & `Composer` to multi-image picking and sending (`PhotosPicker(maxSelectionCount: 10)`, `pendingPhotos: [OutgoingImage]`, horizontal thumbnail strip with individual remove buttons, sequential send with caption on the first photo and partial-failure preservation; unit-tested in `TimelineViewModelTests.multiPhotoAttachAndSend`).
- **Message search fixes (`071fff3`):**
  - Enabled SDK encrypted local search index (`ClientBuilder.withSearchIndexStore(path:key:)`, `enableAutomaticBackPagination(true)`, `runSearchBackfill(.foreground)`) for main-app sessions, fixed `MatrixSearchPort.setQuery` clear/re-search reset (`AdapterContractTests.messageSearch`), and upgraded `MessageSearchView` with always-visible `.searchable` bar, 300 ms debounced auto-search, and `searchedQuery` tracking.
- **Native emoji & emoji input support (`bd4a913`):**
  - Added pure Swift `NativeEmoji` (`HaloDomain/Emoji/NativeEmoji.swift`, `NativeEmojiTests`), jumbo emoji rendering (`TimelineRow.isJumboEmoji` → 48 pt), composer `:shortcode` autocomplete strip, dedicated composer Emoji picker button (`face.smiling`), and upgraded `ReactionPicker` with recents, search, categories, and `NativeEmojiKeyboardField`.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D82), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74:** classic Matrix sync (`syncOnceV2`, `slidingSyncVersionBuilder(.none)`) is the authoritative unread source.
- **D78 (R-01) / D79 (R-07):** SDK counts decide in encrypted rooms (`ENC_SERVER_ONLY` → no unread); E1/E1b yield to positive SDK counts once the SDK applied the read position.
- **D80 / ADR-0020 (R-06):** identity and timeline-index read ordering, `read_intent.timeline_order` (v8), `INTENT_STALE` on confirmed intents (revises D47, D72).
- **D81 (R-17):** removed native sliding-sync gate at server discovery and password login (amends AUTHENTICATION FR-5).
- **D82 / ADR-0021 (founder, supersedes D5):** app icon badge shows total unread messages across rooms needing attention (`BadgeCalculator.badge` sums `RoomReadState.badgeCount` for `attention == true`).

## 4. Modified files (this push)
- **Adapter:** `ios/Packages/HaloMatrixAdapter/Sources/HaloMatrixAdapter/MatrixTimelinePort.swift`, `ios/Packages/HaloMatrixAdapter/Tests/HaloMatrixAdapterTests/AdapterContractTests.swift`.
- **FeatureStickers:** `ios/Packages/Features/FeatureStickers/Sources/FeatureStickers/StickerPanelViewModel.swift`, `ios/Packages/Features/FeatureStickers/Sources/FeatureStickers/StickerPanelView.swift`.
- **FeatureTimeline:** `ios/Packages/Features/FeatureTimeline/Sources/FeatureTimeline/TimelineViewModel.swift`, `ios/Packages/Features/FeatureTimeline/Sources/FeatureTimeline/TimelineView.swift`, `ios/Packages/Features/FeatureTimeline/Tests/FeatureTimelineTests/TimelineViewModelTests.swift`.
- **Docs:** `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Needs the founder**
- 👤 **Gate confirmations:** confirm **G-FFI**, **G-UNREAD**, and **G-NSE** pass outcomes ([docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md) §4; all S01–S29 automated + real-server + iPhone 16 `F-DEV-1`/`F-DEV-2` 100-push G-NSE checks are green).
- 👤 **R-14 (filtering entitlement):** NSE delivers silent empty passive content for suppressed/no-event pushes; request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3) for complete suppression.
- 👤 **R-16 (DB field encryption):** decide whether to implement AES-GCM field encryption using `KeychainItem.haloDatabaseKey` for `draft.body` and `bot_task.title/detail`, or accept plaintext under `completeUntilFirstUserAuthentication` with a new ADR.
- 👤 **R-18 & R-21 (upstream SDK gaps):** pinned `matrix_sdk_ffi.swift` (`26.11.17`, F-FFI-23) `SyncSettingsV2` has no filter (`lazy_load_members` / timeline limit) and `Timeline` has no queued `sendRaw`/`sendSticker`; requires upstream `matrix-rust-sdk` PR + SDK pin bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide whether to build the `infra/sygnal/` Halo pushkin or amend ADR-0015, and configure the Beta/Release push gateway + APNs keys + TestFlight.
- 📱 **Long-horizon physical device soak:** 7-day AC-U8 daily-driver soak (and Release/TestFlight G-NSE spot check once TestFlight is configured).

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. **Await founder input on §5** (G-FFI/G-UNREAD/G-NSE confirmation, R-14, R-16, R-18/R-21, R-24, `Q-MAS-ACCOUNT` / `Q-SDK-BUILD` / `V-LEGAL` before external TestFlight).
2. **Run 7-day AC-U8 daily-driver soak** on a signed device build.

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, and docs/development/OUTSTANDING_ISSUES.md.
All unblocked roadmap items across M0–M10 are implemented and verified (incl.
MAS v1.29.0 dev stack + live OIDC discovery contract, SAS emoji verification,
message search, saved room, room media gallery + export, diagnostics zip
export, and threads).

1. If the founder has answered any of the items in HANDOFF §5 (G-FFI/G-UNREAD
   gate outcomes, R-14, R-16, R-18/R-21, R-24), implement and record those.
2. Otherwise, assist with physical-device builds, TestFlight preparation, or
   long-horizon soaks (G-NSE 100-push run, AC-U8 7-day soak).

Verification on this Mac:
- HALO_SIM="iPhone Air" scripts/prepush.sh
- HALO_SIM="iPhone Air" scripts/contract-test.sh <Suite/test> (infra/dev up)
- Update HANDOFF.md in the last commit before every git push (AGENTS.md §18).
```
