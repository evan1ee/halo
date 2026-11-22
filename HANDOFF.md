# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `main` · PRs #1–#51 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** **Complete for all unblocked items (M0–M10 done).** Every item in [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work" that can be executed without the founder or long-horizon physical-device soaks is implemented and verified. Remaining items wait on the founder or physical-device soaks in §5 ([docs/development/AUTONOMOUS_LOOP.md](docs/development/AUTONOMOUS_LOOP.md) §4).
- **Milestones:** M0–M4, M6–M10 done (G-FFI & G-UNREAD evaluated and recommended **pass** in [docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md), awaiting founder confirmation); M5 done except Beta/Release push gateway + TestFlight and the 7-day AC-U8 soak. Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Codebase review ([docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md)) & outstanding issues ([docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md)):** all 22 executable review findings FIXED; all verifiable items closed with tests; 5 founder decisions remain in §5.
- **Checks:** `HALO_SIM="iPhone Air" scripts/prepush.sh` passes (SwiftLint skipped: not installed/configured); `python3 -I tools/server-rules/check_server_rules.py` 16/16 `ok`; `tools/scenario-driver/run_scenarios.py` 28/28 `ok`; `ServerReadStateScenarioTests/realServerScenarios` passes; `AdapterContractTests/messageSearch` passes (`13.14s`); `infra/dev/smoke-mas.sh` + `AdapterContractTests/oidcDiscovery` pass (`0.821s`); **physical iPhone 16 verified live (`F-DEV-1`)**.
- **CI:** PRs #1–#51 merged. Linux CI covers Foundation, Domain, TestSupport, Application; adapter, persistence, platform, features and the app are validated on Mac via `scripts/prepush.sh` (D71).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log` and [docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md) §13.
- **M5 MAS dev stack & OIDC contract (`V-AUTH-1` resolved, this push on `main`):**
  - Added isolated Synapse + Matrix Authentication Service `v1.29.0` stack (`infra/dev/docker-compose.mas.yml`, `infra/dev/mas/*`, `infra/dev/smoke-mas.sh`) on ports `8009`/`8080` so the native-password `infra/dev` stack on `8008` stays untouched; secrets are generated into Docker volumes at init time.
  - Added `AdapterContractTests.oidcDiscovery` and verified live against Synapse + MAS (`MatrixSessionPort.loginDetails` → `supportsOIDC`, `oauthURL` → `/authorize`, `abortOAuth`, `0.821s`); updated `docs/SOURCES.md`, `docs/OPEN_QUESTIONS.md`, `infra/dev/README.md`, `docs/ROADMAP.md`.
- **M10 Threads (`4e87c55`):**
  - Added `TimelinePort.openThread(room:rootEvent:)` in `HaloDomain`, `FakeTimelinePort`, and `MatrixTimelinePort` (over SDK `Room.timelineWithConfiguration` with `TimelineFocus.thread(rootEventId:)`), extended `TimelineCoordinator(port:room:threadRoot:)`, added "Reply in thread" in `TimelineView`, and wired `ThreadSheet` in `HaloApp` / `AppRoot`.
- **M8 Saved room & M9 Room Media Gallery + Export (`c0c8537`):**
  - Added `ChatCreationPort.openOrCreateSavedRoom()` (`one.mbm.halo.saved_room`), `RoomMediaItem`, `RoomPort.mediaGallery(in:limit:)`, and `RoomMediaGalleryView` with ShareLink export in `FeatureRoomDetails`.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D82), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74:** classic Matrix sync (`syncOnceV2`, `slidingSyncVersionBuilder(.none)`) is the authoritative unread source.
- **D78 (R-01) / D79 (R-07):** SDK counts decide in encrypted rooms (`ENC_SERVER_ONLY` → no unread); E1/E1b yield to positive SDK counts once the SDK applied the read position.
- **D80 / ADR-0020 (R-06):** identity and timeline-index read ordering, `read_intent.timeline_order` (v8), `INTENT_STALE` on confirmed intents (revises D47, D72).
- **D81 (R-17):** removed native sliding-sync gate at server discovery and password login (amends AUTHENTICATION FR-5).
- **D82 / ADR-0021 (founder, supersedes D5):** app icon badge shows total unread messages across rooms needing attention (`BadgeCalculator.badge` sums `RoomReadState.badgeCount` for `attention == true`).

## 4. Modified files (this push)
- **Infra:** `infra/dev/docker-compose.mas.yml`, `infra/dev/mas/init-db.sql`, `infra/dev/mas/mas.dev.yaml`, `infra/dev/mas/homeserver.mas.yaml`, `infra/dev/smoke-mas.sh`, `infra/dev/README.md`.
- **Tests:** `ios/Packages/HaloMatrixAdapter/Tests/HaloMatrixAdapterTests/AdapterContractTests.swift`.
- **Docs:** `docs/SOURCES.md`, `docs/OPEN_QUESTIONS.md`, `docs/ROADMAP.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Needs the founder**
- 👤 **Gate confirmations:** confirm **G-FFI** and **G-UNREAD** pass outcomes in [docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md) §4 (all S01–S29 automated + real-server + iPhone 16 `F-DEV-1` checks are green).
- 👤 **R-14 (filtering entitlement):** NSE delivers silent empty passive content for suppressed/no-event pushes; request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3) for complete suppression.
- 👤 **R-16 (DB field encryption):** decide whether to implement AES-GCM field encryption using `KeychainItem.haloDatabaseKey` for `draft.body` and `bot_task.title/detail`, or accept plaintext under `completeUntilFirstUserAuthentication` with a new ADR.
- 👤 **R-18 & R-21 (upstream SDK gaps):** pinned `matrix_sdk_ffi.swift` (`26.11.17`, F-FFI-23) `SyncSettingsV2` has no filter (`lazy_load_members` / timeline limit) and `Timeline` has no queued `sendRaw`/`sendSticker`; requires upstream `matrix-rust-sdk` PR + SDK pin bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide whether to build the `infra/sygnal/` Halo pushkin or amend ADR-0015, and configure the Beta/Release push gateway + APNs keys + TestFlight.
- 📱 **Long-horizon physical device soaks:** 100-push fault-injection G-NSE run and 7-day AC-U8 daily-driver soak.

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work".
1. **Await founder input on §5** (G-FFI/G-UNREAD confirmation, R-14, R-16, R-18/R-21, R-24, `Q-MAS-ACCOUNT` / `Q-SDK-BUILD` / `V-LEGAL` before external TestFlight).
2. **Run physical-device soaks when ready:** 100-push G-NSE fault-injection soak and 7-day AC-U8 daily-driver soak on a signed device build.

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
