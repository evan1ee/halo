# Halo — Session Handoff

Last updated: 2026-11-20 · Branch: `feat/m4-sticker-preview` · PRs #1–#19 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** M0 done; M1 largely done; M2 done except media sending and the offline-send test; **M3 (read-state engine) in progress**. Dev Mac: Xcode 27.2, Swift 6.4.2, iPhone 16.
- **Checks:** `scripts/prepush.sh` passes (SwiftLint not configured, skipped); `scripts/prepush.sh` now also builds `Halo-Debug` for the simulator. All 15 contract tests (`infra/dev`) pass, none skipped (`scripts/contract-test.sh` after `infra/dev/create-fixtures.py`).
- **CI:** PRs #1–#15 merged. CI runs only the Linux-portable packages (Foundation, Domain, TestSupport, Application): adapter, persistence, platform, features and the app are tested only by `prepush.sh` on a Mac. `licenses` runs only on SDK/inventory changes.

## 2. Completed work (what exists now)
- Layers: HaloFoundation, HaloDomain (ports, pure `ReadStatePolicy`), HaloApplication (coordinators), HaloPersistence (GRDB: `read_intent`, file protection set), HaloMatrixAdapter (only MatrixRustSDK importer), HaloPlatform, HaloTestSupport (fakes), Features/{Auth,RoomList,Timeline}. Composition root `ios/App/AppRoot.swift`; project generated from `ios/project.yml` (XcodeGen, scheme `Halo-Debug`).
- Read state: `BadgeCoordinator` = count of rooms with attention from `ReadStatePolicy`; inputs are server/SDK counts, `latestEvent`, the local read position (`ReadReceiptCoordinator.positions()`), the user's own receipt from other devices (`RoomSummary.ownReadThrough`) and notification records.
- Outbound receipts: timeline rows report visibility (`onScrollVisibilityChange(threshold: 0.5)`, plus a 0.5 s dwell in the view model: D6) → `ReadReceiptCoordinator` (monotonic, 2 s debounce, backoff, persisted and restored, 7-day expiry of sent intents) → `MatrixReadMarkerPort`.
- Room list rows show the policy's unread indicator (count / mentions / dot, bold when unread) and update when the local read position changes.
- `RoomListCoordinator(loadsAllPages: true)` (app) keeps paging so the badge sees every room.
- Pushed events (notification records) at or before the read position (here or another device) no longer count; delivered notifications of rooms without attention are removed by `SystemBadge`.
- Property tests P1–P6, P5b, P9, P10 (10,000 seeded cases each) in `HaloDomainTests/ReadStatePropertyTests.swift`; P7 in `BadgeCoordinatorTests` (records JSON round trip); P8 in `ReadIntentStoreTests` (concurrent upserts). P3 = notified-event order; P4 = re-evaluation, and repeating a notified event never changes attention (counts may; the store dedups by event ID). Scenarios S01–S22 are written as model-based tests (`HaloApplicationTests/ReadStateScenarioTests.swift`: real policy and coordinators over an in-process model of Synapse and A1's sync; not run against a real server).
- Sign-out removes the pusher first (`PushPort.unregister` → `deletePusher`, via `SessionCoordinator.setBeforeSignOut`; best effort).
- Messaging: a confirmed own message becomes the read position (FR-6, `TimelineViewModel.reportOwnMessage`); failed local echoes can be retried or deleted from the long-press menu (FR-3: `TimelineEvent.localID`, `TimelineSession.retrySend/abortSend`, adapter over `Timeline.retrySend/abortSend`).
- Drafts (FR-5): `DraftPort` → `DraftStore` (table `draft`, migration `v3-draft`) behind `DraftCoordinator` (in-memory first, store attached after sign-in); `TimelineViewModel` restores and saves the composer text per room and keeps it across an edit.
- Mentions (FR-1, AC-M2): typing `@` offers joined members (`TimelineSession.members`), picking one inserts `@Name `; `MentionFormatter` (pure, HaloDomain) turns remaining `@Name` into `matrix.to` links in the formatted body and the adapter sets `m.mentions` via `withMentions`. A restored draft keeps the text but not the picked mentions.
- Stickers v1 (M4, in progress): `HaloDomain/Stickers` (`ImagePackParser`, `ShortcodeRules`, `StickerPrefs` incl. account-data form and merge, `StickerSearch`), ports `StickerPackPort`/`StickerPrefsPort`, `StickerLibrary` (debounced recents, merge with remote), `TimelineSession.sendSticker` (`send_raw` `m.sticker`, no local echo), adapter `MatrixStickerPorts` (packs read with an authenticated GET of the room state: V-ST-1 option B, option A was verified empty; current-room packs: whole state only for rooms ≤ 1,000 joined members, else the empty-key pack, cached 10 min, ephemeral `URLSession`: D68), package `FeatureStickers` (panel VM and view) opened from a composer button, incoming stickers shown as images.
- Image sending (M2): `PhotosPicker` in the composer → `TimelineViewModel.sendImage` → `ImagePreparing` (`HaloPlatform.ImagePreparer`: ImageIO, orientation applied, max 2048 px, re-encoded as JPEG/PNG so EXIF/GPS is dropped, animated GIF kept) → `TimelineSession.sendImage` (`Timeline.sendAttachment` with in-memory data). Verified on `infra/dev` by contract test `sendImage` (upload, event in timeline, bytes back through the media port). No caption, no video/audio/file sending.
- Pack creation (FR-7): `NewPackView/ViewModel` (FeatureStickers, opened by "+" in the panel) → `StickerPackCreator` (512 px via `ImagePreparer`, valid unique shortcodes, 5 MB cap) → `StickerPackCreationPort` (`MatrixStickerPackCreationPort`: uploads, unencrypted private room "Sticker pack: <name>", `m.room.image_pack`, `m.image_pack.rooms` and `one.mbm.halo.sticker_rooms` read-modify-write, unknown keys preserved; on a failure after the room exists the pack is disabled again and the room left and forgotten). Verified on `infra/dev` by contract test `createPack` (round trip through the pack reader and the media port). Pack rooms listed in `one.mbm.halo.sticker_rooms` are hidden from the room list and the badge (`HiddenRoomsPort` → `RoomListCoordinator(hiddenRooms:)`, re-read after every list change; verified: unit tests and the `createPack` contract test reads the list back; not checked on screen, and a pack room created on another device shows until the next list change).
- Account change (D69): on sign-out or a different account, `AppRoot.followReadIntents` calls `reset()` on `ReadReceiptCoordinator`, `DraftCoordinator` and `StickerLibrary` (generation counters drop results of work started for the old account); before sign-out pending receipts and sticker recents are flushed, then the pusher is removed. The same account becoming ready again doesn't reopen the database.
- Read-state auditor (debug builds): `ReadStateAuditor` + `AuditEventPort`/`AuditEventStore` (`audit_event`, migration `v4-audit-event`, 5,000 rows) wired into `BadgeCoordinator.setAudit` from `AppRoot`; see LOGGING_AND_DIAGNOSTICS §2. Not run on a device; the 10-minute re-run, diagnostics export and Settings counter are not built.
- Room list swipe: leading "Read" (`markRoomRead`), trailing "Unread" (`setMarkedUnread`).

## 3. Key decisions
**D73 (founder): V-RS-7 closed.** Classic Matrix sync is the authoritative unread evidence on the production path; push records supplement it; server zero never marks read by itself; a partial or empty evaluation never overwrites the stored attention set; badge from reconciled state; no SDK/Synapse change unless proven necessary; unread correctness and badge persistence are **P0**. Verified: the SDK exposes per-room evidence over `syncV2` (`ClassicSyncEvidenceTests`); classic sync does not solve the NSE's background state (records + cached set stay its inputs). **Implemented by D74:** the adapter runs classic sync (own `syncOnceV2` loop, 8 s long poll), room list from `client.rooms()` plus the rooms each response changed; verified live in the simulator (unread `@1` and bold within seconds).

Full list: docs/DECISION_LOG.md (D1–D74), docs/adr/. Most relevant now: D70 autonomous loop with self-merge (docs/development/AUTONOMOUS_LOOP.md); D5/D9 badge = rooms needing attention; D47 `readPosTs` vs `notifiedThroughTs`; D6 visibility rule; D7 private receipts; D17 unthreaded receipts; D65/ADR-0015 pushes never set the badge.

## 4. Modified files (this push)
`FeatureStickers` (`StickerImage.swift`, `StickerPanelView` preview, `StickerPanelViewModel.previewContent`, `StickerImageTests`), `MediaLoader.content`, `ROADMAP.md`, `HANDOFF.md`. Earlier push: `ClassicSyncEvidenceTests` (`encryptedEvidence`: two SDK clients, encrypted room, all-messages and mentions-only), `docs/testing/UNREAD_REGRESSION_TESTS.md`, `ROADMAP.md`, `HANDOFF.md`.

## 5. Outstanding issues
- Stickers: V-ST-1 resolved (option B), V-ST-2 partly (token refresh on 401 not exercised). Verified against `infra/dev` by contract test `stickers` (env `HALO_DEV_STICKER_ROOM`: a room with `m.room.image_pack` `cats` {wave, dance} enabled in `m.image_pack.rooms`; throwaway account `stickertester` created locally). Long-press preview with animation is built (FR-5, FR-9: `StickerImage`, `AnimatedStickerView`; grid stays static, not checked on screen; `FeatureStickers` UIKit tests run only on the simulator: `xcodebuild -scheme FeatureStickers test`). Not built: editing/deleting packs, hiding pack rooms from the room list, legacy `im.ponies.*` packs (V-ST-3), privacy notice, "unavailable pack" UI. Real sticker images were not loaded (the fixture mxc URLs have no media).
- Mentions: the formatted body link and the escaping of a hostile display name (no HTML, emphasis or second link) are verified against `infra/dev` (`mentionsAndEchoes`); `m.mentions`, Element Web pill rendering and `Room.members()` cost in large rooms are not.
- Pack-creation cleanup (leave/forget after a failure) is not exercised against a server; the success path is. In rooms over 1,000 members, packs with a non-empty state key are only offered if the user enabled them.
- Each `createPack` contract run leaves one more pack enabled on the test account (the `stickers` test tolerates it).
- `retrySend`/`abortSend` verified only for an unknown echo (contract test `mentionsAndEchoes`: `.notFound`); a real failed echo was not retried against the server.
- Opening a room now clears `m.marked_unread` (`ReadReceiptCoordinator.roomOpened`, called by `TimelineViewModel`; the adapter skips the write when the flag is already clear). Unverified on a device/server.
- S01–S22 validate Halo against a model of Synapse. Verified: count rules (see above) and the server half of 15 scenarios, 28 checks (`tools/scenario-driver/run_scenarios.py`; run it after changing the dev Synapse). Unverified: sliding sync (V-RS-7: Synapse serves 0 counts there), limited timelines, own-receipt delivery to a second device (V-RS-1), the SDK's own counts.
- Unverified on a device: file protection class on `halo.sqlite` (simulator reports none), V-RS-1 (do own-receipt changes trigger room-list updates?), cost of `loadOrFetchEvent` lookups, kill-and-relaunch resend, NSE access to the database, paging cost for large accounts, the swipe UI and the unread indicators.
- D6 verified in the simulator (iOS 26.0, `infra/dev`): `onScrollVisibilityChange` fires for `List` rows; the receipt followed the newest visible message ("D6 line 4" on opening, "D6 line 15" after scrolling). Not an automated UI test. Observed: a room with 40 unread messages opens at its oldest events ("This is the start of the conversation"), not at the first unread or the bottom; TIMELINE.md §1 specifies landing at the first unread message (or the bottom): queued in ROADMAP M2 leftovers. The room list shows no unread indicator for it (V-RS-7: sliding sync counts are 0).
- `read_intent`: `receipt_type` always `read`; failed sends count in `attempts`/`last_error` and are logged; confirmation rules (a)/(b) not built (D72), sent intents expire after 7 days.
- Timeline/Media contract tests need a fixture room (`HALO_DEV_TIMELINE_ROOM`: first, second, notice, waves, redacted message, blue.png). Run contracts with `TEST_RUNNER_HALO_DEV_*`; the server value must be `http://localhost:8008`. Parallel contract tests on one account hang (suite is serialized).
- Classic sync (D74) not yet measured on a large account (first `/sync` has no filter: all members, default timeline); `loadsAllPages`/paging in `RoomListCoordinator` is now a no-op; sync errors other than retryable network end the loop with `.failed`; cancelling the loop doesn't interrupt the SDK long poll (8 s).
- Open validation: V-CI-2, V-SQL-1, V-APPLE-1, V-NSE-*, V-PUSH-1/3/5, V-RS-1/5 (V-RS-7 closed by D73).
- Docker CLI hangs on the `osxkeychain` helper; use a throwaway `DOCKER_CONFIG`.  Compose is missing under a throwaway config: use `docker exec`/`docker restart`.
- Contract tests: `infra/dev/create-fixtures.py` creates accounts/rooms and writes `~/.config/halo-dev/contract.env`; re-run it before a full `scripts/contract-test.sh` (room count) and with `--new-e2ee` before the Encryption test (recovery can be set up once per account). Verified: 15 of 15 pass (twice in a row; incl. `policyOverRealInputs`) (`pusher`, `ClassicSyncEvidenceTests` incl. `encryptedEvidence`). Contract tests must leave no room on the account (the room count is a fixture); the timeline fixture room grows ~13 events per run.

**Needs the founder** (the loop records these and moves on; AUTONOMOUS_LOOP §5)
- 📱 Device checks: G-NSE AC-NSE-1…6, V-RS-1, file protection on `halo.sqlite`, NSE database access, background push delivery.
- 👤 Gate outcomes G-UNREAD / G-FFI: evaluation written ([testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md)); agent recommends G-FFI **pass** (stay upstream, two conditions) and G-UNREAD **stay open** until the classic-sync adapter and the S01–S22 re-run are done (V-RS-7 decided: D73) and the 📱 checks are done; push gateway, APNs keys, TestFlight.

**Deferred (not blocking):** Q-CI-MAC (D71, founder): no macOS CI job for now; `scripts/prepush.sh` stays the only Mac validation gate. Revisit once the build pipeline is stable and a hosted runner is confirmed to have the required Xcode.

## 6. Next steps
The queue is docs/ROADMAP.md §"Remaining work", worked by the loop in docs/development/AUTONOMOUS_LOOP.md. Its head:
1. **P0** the remaining client-side scenarios on the real stack (S03, S11, S12, S16–S20: restarts, outbox, NSE; most need a device), then re-evaluate G-UNREAD with the founder; measure the first-sync cost on a large account; M4 items after.

## 7. Next Session Prompt
```text
/loop Continuously execute the roadmap in a loop: **Plan → Implement → Verify**. Once a milestone is completed and verified, immediately proceed to the next milestone. Continue autonomously until roadmap finished.

Context for the loop (Halo, repository evan1ee/halo):
1. Read AGENTS.md, HANDOFF.md, then docs/development/AUTONOMOUS_LOOP.md. Trust HANDOFF for project state.
   Run scripts/install-hooks.sh once per clone.
2. The work queue is docs/ROADMAP.md §"Remaining work"; HANDOFF §6 is its head. One branch and one PR per item.
3. Verify every SDK API in the pinned source (ios/SDKVERSION.md); never invent names.
4. Verify each item: scripts/prepush.sh, the Halo-Debug app build, touched contract tests against infra/dev,
   a simulator check for UI. Report real output; say what you couldn't run.
5. Review the diff; fix high/medium findings. Merge your own PR only under AUTONOMOUS_LOOP §3 (all CI checks
   passed, `gh pr merge --merge --delete-branch`), then branch again from main.
6. Device, signing, gate-outcome, dependency and product decisions go to HANDOFF §5 "Needs the founder";
   move on to the next item instead of stopping. Do not ask whether to continue.
7. Before every git push (AGENTS.md §18): HANDOFF.md rewritten as state and next steps, ROADMAP ticked,
   specs/OPEN_QUESTIONS/DECISION_LOG updated, HANDOFF.md in the last commit of the push.
```
