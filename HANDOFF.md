# Halo — Session Handoff

Last updated: 2026-11-20 · Branch: `claude/m0b-adapter-scaffold` · local commits not pushed

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** M0 done; M1 and M2 largely done; **M3 (read-state engine) in progress**. Dev Mac: Xcode 27.2, Swift 6.4.2, iPhone 16.
- **Checks:** `scripts/prepush.sh` passes (SwiftLint not configured, skipped). Contract tests (`infra/dev`) pass for Session, RoomList, Sync, ReadMarker.
- **CI:** PR #1/#2 merged; this branch's CI results not reviewed. `licenses` runs only on SDK/inventory changes.

## 2. Completed work (what exists now)
- Layers: HaloFoundation, HaloDomain (ports, pure `ReadStatePolicy`), HaloApplication (coordinators), HaloPersistence (GRDB: `read_intent`, file protection set), HaloMatrixAdapter (only MatrixRustSDK importer), HaloPlatform, HaloTestSupport (fakes), Features/{Auth,RoomList,Timeline}. Composition root `ios/App/AppRoot.swift`; project generated from `ios/project.yml` (XcodeGen, scheme `Halo-Debug`).
- Read state: `BadgeCoordinator` = count of rooms with attention from `ReadStatePolicy`; inputs are server/SDK counts, `latestEvent`, the local read position (`ReadReceiptCoordinator.positions()`), the user's own receipt from other devices (`RoomSummary.ownReadThrough`) and notification records.
- Outbound receipts: timeline rows report visibility (approximation of D6) → `ReadReceiptCoordinator` (monotonic, 2 s debounce, backoff, persisted and restored, 7-day expiry of sent intents) → `MatrixReadMarkerPort`.
- Room list rows show the policy's unread indicator (count / mentions / dot, bold when unread) and update when the local read position changes.
- `RoomListCoordinator(loadsAllPages: true)` (app) keeps paging so the badge sees every room.
- Pushed events (notification records) at or before the read position (here or another device) no longer count; delivered notifications of rooms without attention are removed by `SystemBadge`.
- Property tests P1–P6, P5b, P9, P10 (10,000 seeded cases each) in `HaloDomainTests/ReadStatePropertyTests.swift`; P7 in `BadgeCoordinatorTests` (records JSON round trip); P8 in `ReadIntentStoreTests` (concurrent upserts). P3 = notified-event order; P4 = re-evaluation, and repeating a notified event never changes attention (counts may; the store dedups by event ID). Scenarios S01–S22 are not written.
- Sign-out removes the pusher first (`PushPort.unregister` → `deletePusher`, via `SessionCoordinator.setBeforeSignOut`; best effort).
- Room list swipe: leading "Read" (`markRoomRead`), trailing "Unread" (`setMarkedUnread`).

## 3. Key decisions
Full list: docs/DECISION_LOG.md (D1–D67), docs/adr/. Most relevant now: D5/D9 badge = rooms needing attention; D47 `readPosTs` vs `notifiedThroughTs`; D6 visibility rule; D7 private receipts; D17 unthreaded receipts; D65/ADR-0015 pushes never set the badge.

## 4. Modified files (this push)
Everything in `git log origin/main..HEAD`. Key paths: `ios/Packages/HaloApplication/Sources/HaloApplication/{ReadReceipts,Badge,RoomList}`, `HaloMatrixAdapter/.../{MatrixReadMarkerPort,MatrixRoomListPort}.swift`, `HaloPersistence/.../{HaloDatabase,ReadIntentStore}.swift`, `Features/{FeatureTimeline,FeatureRoomList}`, `ios/App/{AppRoot,HaloApp}.swift`.

## 5. Outstanding issues
- Unverified on a device: file protection class on `halo.sqlite` (simulator reports none), V-RS-1 (do own-receipt changes trigger room-list updates?), cost of `loadOrFetchEvent` lookups, kill-and-relaunch resend, NSE access to the database, `deletePusher` (no contract test), paging cost for large accounts, the swipe UI and the unread indicators, the `latestEvent` mapping (no unit test).
- D6 (≥ 50 % visible for ≥ 0.5 s) is approximated by row appear/disappear.
- `read_intent`: `receipt_type` always `read`; `attempts`/`last_error` unused; no intent confirmation rules (a)–(c) (sent intents just expire).
- No `HaloLog` in `ReadReceiptCoordinator` (storage errors only kept in `lastStorageError`).
- Timeline/Media contract tests need a fixture room (`HALO_DEV_TIMELINE_ROOM`: first, second, notice, waves, redacted message, blue.png). Run contracts with `TEST_RUNNER_HALO_DEV_*`; the server value must be `http://localhost:8008`. Parallel contract tests on one account hang (suite is serialized).
- Open validation: V-CI-2, V-SQL-1, V-APPLE-1, V-NSE-*, V-PUSH-1/3/5, V-RS-1/5, V-RS-7 (Synapse sliding sync serves 0 counts).
- Docker CLI hangs on the `osxkeychain` helper; use a throwaway `DOCKER_CONFIG`.

## 6. Next steps
1. M3: true ≥ 50 % visibility; scenario tests S01–S22 (Synapse in Docker, scenario driver) and auditor.
2. Device checks from section 5; G-NSE hardening (peak memory, encrypted room, timeout injection AC-NSE-3/4, 100 pushes, Release build).
3. M2 left: offline send test, media sending, mentions. M1 left: video/audio/file, QR/emoji verification. A push gateway for Beta/Release.
4. Push the branch, open a PR, check CI (after refreshing this file).

## 7. Next Session Prompt
```text
Continue development of Halo (repository evan1ee/halo), branch claude/m0b-adapter-scaffold.

1. Read AGENTS.md, then HANDOFF.md. Trust it for project state; read other docs only as the task needs them.
   Run scripts/install-hooks.sh once.
2. Work through HANDOFF.md section 6 autonomously, in small steps: plan, implement, verify, commit,
   then the next step. Do not ask whether to continue; stop only for a real decision or blocker.
3. Verify every SDK API in the pinned source (ios/SDKVERSION.md); never invent names.
4. Run scripts/prepush.sh and report real output; say what you couldn't run. Tests for every behaviour
   change; Conventional Commits; docs in the same commit.
5. Before every git push (AGENTS.md §18): rewrite HANDOFF.md as state and next steps only (no changelog),
   update ROADMAP/OPEN_QUESTIONS/specs, and include HANDOFF.md in the last commit of the push.
```
