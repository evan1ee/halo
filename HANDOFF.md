# Halo — Session Handoff

Last updated: 2026-11-20 · Branch: `claude/m0b-adapter-scaffold` · PR #5 open (Auto-fix on)

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** M0 done; M1 largely done; M2 done except media sending and the offline-send test; **M3 (read-state engine) in progress**. Dev Mac: Xcode 27.2, Swift 6.4.2, iPhone 16.
- **Checks:** `scripts/prepush.sh` passes (SwiftLint not configured, skipped); the app target builds (`Halo-Debug`, simulator; prepush doesn't build it). Contract tests (`infra/dev`) pass for Session, RoomList, Sync, ReadMarker, stickers, createPack, mentionsAndEchoes.
- **CI:** PR #1/#2 merged; PR #5 green. CI runs only the Linux-portable packages (Foundation, Domain, TestSupport, Application): adapter, persistence, platform, features and the app are tested only by `prepush.sh` on a Mac. `licenses` runs only on SDK/inventory changes.

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
- Pack creation (FR-7): `NewPackView/ViewModel` (FeatureStickers, opened by "+" in the panel) → `StickerPackCreator` (512 px via `ImagePreparer`, valid unique shortcodes, 5 MB cap) → `StickerPackCreationPort` (`MatrixStickerPackCreationPort`: uploads, unencrypted private room "Sticker pack: <name>", `m.room.image_pack`, `m.image_pack.rooms` and `one.mbm.halo.sticker_rooms` read-modify-write, unknown keys preserved; on a failure after the room exists the pack is disabled again and the room left and forgotten). Verified on `infra/dev` by contract test `createPack` (round trip through the pack reader and the media port). The `sticker_rooms` list is written but nothing hides those rooms from the room list yet.
- Account change (D69): on sign-out or a different account, `AppRoot.followReadIntents` calls `reset()` on `ReadReceiptCoordinator`, `DraftCoordinator` and `StickerLibrary` (generation counters drop results of work started for the old account); before sign-out pending receipts and sticker recents are flushed, then the pusher is removed. The same account becoming ready again doesn't reopen the database.
- Room list swipe: leading "Read" (`markRoomRead`), trailing "Unread" (`setMarkedUnread`).

## 3. Key decisions
Full list: docs/DECISION_LOG.md (D1–D70), docs/adr/. Most relevant now: D70 autonomous loop with self-merge (docs/development/AUTONOMOUS_LOOP.md); D5/D9 badge = rooms needing attention; D47 `readPosTs` vs `notifiedThroughTs`; D6 visibility rule; D7 private receipts; D17 unthreaded receipts; D65/ADR-0015 pushes never set the badge.

## 4. Modified files (this push)
`scripts/contract-test.sh` and `infra/dev/contract.env.example` (new); docs: `docs/development/AUTONOMOUS_LOOP.md` (new), `docs/ROADMAP.md` (§"Remaining work" = the loop's queue), `AGENTS.md` (§0 step 8, §16), `docs/DECISION_LOG.md` (D70), `docs/development/CI_CD.md`, `HANDOFF.md`. The code of PR #5 is in `git log origin/main..HEAD`.

## 5. Outstanding issues
- Stickers: V-ST-1 resolved (option B), V-ST-2 partly (token refresh on 401 not exercised). Verified against `infra/dev` by contract test `stickers` (env `HALO_DEV_STICKER_ROOM`: a room with `m.room.image_pack` `cats` {wave, dance} enabled in `m.image_pack.rooms`; throwaway account `stickertester` created locally). Not built: long-press preview/animation (FR-5, FR-9), editing/deleting packs, hiding pack rooms from the room list, legacy `im.ponies.*` packs (V-ST-3), privacy notice, "unavailable pack" UI. Real sticker images were not loaded (the fixture mxc URLs have no media).
- Mentions: the formatted body link and the escaping of a hostile display name (no HTML, emphasis or second link) are verified against `infra/dev` (`mentionsAndEchoes`); `m.mentions`, Element Web pill rendering and `Room.members()` cost in large rooms are not.
- Pack-creation cleanup (leave/forget after a failure) is not exercised against a server; the success path is. In rooms over 1,000 members, packs with a non-empty state key are only offered if the user enabled them.
- Each `createPack` contract run leaves one more pack enabled on the test account (the `stickers` test tolerates it).
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
- Contract tests: `scripts/contract-test.sh [test …]`, settings in `~/.config/halo-dev/contract.env` (outside the repo; template `infra/dev/contract.env.example`). On the dev Mac it holds `stickertester` and the sticker room: the full suite gives 11 tests, 7 passing and 4 skipped (Timeline, Media, ReadMarker need `HALO_DEV_TIMELINE_ROOM`; Encryption needs `HALO_DEV_E2EE_USER`). Those fixtures are not created for this account yet.

**Needs the founder** (the loop records these and moves on; AUTONOMOUS_LOOP §5)
- 📱 Device checks: G-NSE AC-NSE-1…6, V-RS-1, file protection on `halo.sqlite`, NSE database access, background push delivery.
- 👤 Gate outcomes G-UNREAD / G-FFI at the end of M3 (the agent writes the evaluation); push gateway, APNs keys, TestFlight.

## 6. Next steps
The queue is docs/ROADMAP.md §"Remaining work", worked by the loop in docs/development/AUTONOMOUS_LOOP.md. Its head:
1. Merge PR #5 when CI on its last push is green (AUTONOMOUS_LOOP §3), then `git switch main && git pull --ff-only`.
2. macOS CI job for the Mac-only packages and the app build; app build in `scripts/prepush.sh`.
3. M3: scenario driver running S01–S22 against Synapse in `infra/test`, then the auditor.

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
