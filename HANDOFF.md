# Halo — Session Handoff

Last updated: 2026-11-20 · Branch: `claude/m0b-adapter-scaffold` · local commits not pushed

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** M0 done; M1 largely done; M2 done except media sending and the offline-send test; **M3 (read-state engine) in progress**. Dev Mac: Xcode 27.2, Swift 6.4.2, iPhone 16.
- **Checks:** `scripts/prepush.sh` passes (SwiftLint not configured, skipped). Contract tests (`infra/dev`) pass for Session, RoomList, Sync, ReadMarker.
- **CI:** PR #1/#2 merged; this branch's CI results not reviewed. `licenses` runs only on SDK/inventory changes.

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
- Stickers v1 (M4, in progress): `HaloDomain/Stickers` (`ImagePackParser`, `ShortcodeRules`, `StickerPrefs` incl. account-data form and merge, `StickerSearch`), ports `StickerPackPort`/`StickerPrefsPort`, `StickerLibrary` (debounced recents, merge with remote), `TimelineSession.sendSticker` (`send_raw` `m.sticker`, no local echo), adapter `MatrixStickerPorts` (packs read with an authenticated GET of the room state: V-ST-1 option B, option A was verified empty), package `FeatureStickers` (panel VM and view) opened from a composer button, incoming stickers shown as images.
- Room list swipe: leading "Read" (`markRoomRead`), trailing "Unread" (`setMarkedUnread`).

## 3. Key decisions
Full list: docs/DECISION_LOG.md (D1–D67), docs/adr/. Most relevant now: D5/D9 badge = rooms needing attention; D47 `readPosTs` vs `notifiedThroughTs`; D6 visibility rule; D7 private receipts; D17 unthreaded receipts; D65/ADR-0015 pushes never set the badge.

## 4. Modified files (this push)
Everything in `git log origin/main..HEAD`. Key paths: `ios/Packages/HaloApplication/Sources/HaloApplication/{ReadReceipts,Badge,RoomList}`, `HaloMatrixAdapter/.../{MatrixReadMarkerPort,MatrixRoomListPort}.swift`, `HaloPersistence/.../{HaloDatabase,ReadIntentStore}.swift`, `Features/{FeatureTimeline,FeatureRoomList}`, `ios/App/{AppRoot,HaloApp}.swift`.

## 5. Outstanding issues
- Stickers: V-ST-1 resolved (option B), V-ST-2 partly (token refresh on 401 not exercised). Verified against `infra/dev` by contract test `stickers` (env `HALO_DEV_STICKER_ROOM`: a room with `m.room.image_pack` `cats` {wave, dance} enabled in `m.image_pack.rooms`; throwaway account `stickertester` created locally). Not built: long-press preview/animation (FR-5, FR-9), pack creation (FR-7), legacy `im.ponies.*` packs (V-ST-3), privacy notice, "unavailable pack" UI. Real sticker images were not loaded (the fixture mxc URLs have no media).
- Mentions: the formatted body link is verified against `infra/dev` (`mentionsAndEchoes`); `m.mentions`, Element Web pill rendering and `Room.members()` cost in large rooms are not.
- `retrySend`/`abortSend` verified only for an unknown echo (contract test `mentionsAndEchoes`: `.notFound`); a real failed echo was not retried against the server.
- Opening a room now clears `m.marked_unread` (`ReadReceiptCoordinator.roomOpened`, called by `TimelineViewModel`; the adapter skips the write when the flag is already clear). Unverified on a device/server.
- S01–S22 validate Halo against a model of Synapse. Verified: count rules (see above). Unverified: sliding sync (V-RS-7: Synapse serves 0 counts there), limited timelines, own-receipt delivery to a second device (V-RS-1), the SDK's own counts.
- Unverified on a device: file protection class on `halo.sqlite` (simulator reports none), V-RS-1 (do own-receipt changes trigger room-list updates?), cost of `loadOrFetchEvent` lookups, kill-and-relaunch resend, NSE access to the database, `deletePusher` (no contract test), paging cost for large accounts, the swipe UI and the unread indicators, the `latestEvent` mapping (no unit test).
- D6: the ≥ 50 % rule relies on `onScrollVisibilityChange` inside a `List`; builds, but not verified on a device that it fires for List rows (fall back to a ScrollView/LazyVStack if not).
- `read_intent`: `receipt_type` always `read`; `attempts`/`last_error` unused; no intent confirmation rules (a)–(c) (sent intents just expire).
- No `HaloLog` in `ReadReceiptCoordinator` (storage errors only kept in `lastStorageError`).
- Timeline/Media contract tests need a fixture room (`HALO_DEV_TIMELINE_ROOM`: first, second, notice, waves, redacted message, blue.png). Run contracts with `TEST_RUNNER_HALO_DEV_*`; the server value must be `http://localhost:8008`. Parallel contract tests on one account hang (suite is serialized).
- Open validation: V-CI-2, V-SQL-1, V-APPLE-1, V-NSE-*, V-PUSH-1/3/5, V-RS-1/5, V-RS-7 (Synapse sliding sync serves 0 counts).
- Docker CLI hangs on the `osxkeychain` helper; use a throwaway `DOCKER_CONFIG`.

## 6. Next steps
1. M3: device check of the ≥ 50 % visibility; the Docker scenario driver to run S01–S22 against Synapse; the auditor.
2. Device checks from section 5; G-NSE hardening (peak memory, encrypted room, timeout injection AC-NSE-3/4, 100 pushes, Release build).
3. M4 left: preview/animation, pack creation (FR-7), legacy packs. M2 left: offline send test, media sending. M1 left: video/audio/file, QR/emoji verification. A push gateway for Beta/Release.
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
