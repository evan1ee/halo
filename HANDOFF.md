# Halo — Session Handoff

Last updated: 2026-11-19 · Branch: `claude/m0b-adapter-scaffold` · PRs #1, #2 merged; this branch not yet pushed

Updated in the last commit of every push (AGENTS.md §18). Summarises and links; the facts live in `docs/`.

## 1. Current status
- **Milestone:** M0 Foundation, split because no Mac is available yet (docs/ROADMAP.md → "M0 without a Mac").
  **M0 done; M1 and M2 largely done on a Mac (Xcode 27.2, Swift 6.4.2) and a physical iPhone 16 (see the newest entries).**
- **Phase 0 documentation:** approved by the founder (2026-11-19).
- **CI:** workflows `docs`, `swift-linux`, `boundaries`, `secrets`, `handoff` run on PR #1 (first run there; results not yet
  reviewed in a session). `licenses` runs only when SDK/inventory files change.
- **Local checks at this push:** `scripts/prepush.sh` — handoff, docs, boundaries, 4 Swift packages (Swift 6.2.4 Linux), gitleaks
  pass; SwiftLint skipped (not configured). Apple-only packages, the adapter (iOS simulator) and the signed app for a physical device have all been built and run.
  gitleaks 8.30.1 is now installed locally (`brew install gitleaks`) and `scripts/prepush.sh` runs it; CI's first run on PR #3 flagged a UserDefaults key name as `generic-api-key`, fixed by renaming the
  constants and a one-line `.gitleaksignore` for the old commit's fingerprint (history scans see it).

## 2. Completed work
**2026-11-20 (latest+19) — Local read intent and latest event feed the badge policy**
- `RoomSummary.latestEvent` (adapter: `Room.latestEvent()`; remote → time + `isOwn`, local echo → own, none/invite → nil) → `RoomReadInputs.latestEvent`. `ReadReceiptCoordinator.positions()` streams the per-room read time;
  `BadgeCoordinator(receipts:)` passes it as `localIntent`, so rule E1 clears a room's attention the moment the user reads it here (even while the server still counts) and a newer event brings it back.
- Checked: HaloApplication 59 tests (new `localIntentClears`), app and adapter build, room-list/session/sync/receipt contracts pass on infra/dev (Timeline/Media contracts need their fixture room). NOT checked: the
  `latestEvent` mapping has no unit test (the SDK enum needs heavy fixtures) and wasn't observed on the device; own receipts from other devices are still not read back (V-RS-1), so reading on another device doesn't clear here.

**2026-11-20 (latest+18) — Read intents persisted (GRDB) and restored**
- `ReadIntentPort`/`ReadIntent` (domain), `FakeReadIntents`, `HaloPersistence.ReadIntentStore` + migration `v2-read-intent` (table per docs/data/DATA_MODELS.md; monotonic upsert, a sent intent never reverts to pending,
  scoped by account, `removeSent(createdBefore:)`). `ReadReceiptCoordinator` (also: ReadMarkerPort, 2 s per-room debounce, backoff 1 s → 5 min, `flush()`) saves every intent and the sent state; `restore(from:)` loads them,
  drops sent intents older than 7 days and sends unsent ones; `lastStorageError` records a storage failure (intents still work from memory; no logging yet). App: `HaloPersistence` added to `ios/project.yml` (project
  regenerated), `AppRoot.followReadIntents()` opens `halo/halo.sqlite` in the store directory when a session is ready.
- **Bug found and fixed:** two overlapping sends for one room (actor re-entrancy across the network await) could send the same receipt twice; `sending` guard added. Caught as a flaky burst test (5 of 15 runs); 20 runs clean after the fix.
- Checked: HaloPersistence 5 tests, HaloApplication 58, app builds for the simulator, `scripts/prepush.sh` passes. NOT verified: the DB file on a device (App Group path; file protection `completeUntilFirstUserAuthentication` isn't
  set on it yet), that a kill-and-relaunch actually resends, multi-process (NSE) access; `receipt_type` is always `read` (private receipts aren't stored); `attempts`/`last_error` columns unused.

**2026-11-20 (latest+17) — Outbound read receipts wired end to end**
- `TimelineViewModel(receipts:room:)`: rows report `rowVisibility(_:isVisible:)` (List `onAppear`/`onDisappear`), `setActive` follows `scenePhase`; the newest visible *confirmed* event that stays visible for 0.5 s while active is
  passed to `ReadReceiptCoordinator.reportSeen`. `AppRoot` owns one coordinator over `MatrixReadMarkerPort`; `HaloApp` flushes it when the scene leaves `.active`.
- Checked: FeatureTimeline 19 tests (new `readReceipts`); app builds for the simulator; adapter contract `ReadMarkerPort` passes against infra/dev (public + private receipt, fully-read marker, unknown room → `.notFound`; run with a throwaway user).
  In that run the Timeline/Media contracts timed out only because the throwaway room lacks their fixture content.
- Limits: "visible" is List row appearance, not the D6 ≥ 50 % area rule (approximation); the top-most-screen condition is `scenePhase` + the screen's lifetime only; not looked at on screen, so no check that the receipt shows on a second client; `read_intent`
  persistence, `ownReceipt` read-back and confirmation rules (a)–(c) are still not built.

**2026-11-19 (latest+15) — Badge: read-state policy, BadgeCalculator, badge on the icon**
- `HaloDomain/ReadState`: `RoomReadInputs`/`RoomReadCounts`/`ServerCounts`/`SDKCounts`, `ReadStatePolicy.evaluate` (rules E0, E1/E1b, E2/E2x, E3a/b/c, E4, E5, modes, `hasUnread`, display, confidence, reason codes) and
  `BadgeCalculator` (= rooms with attention). 11 unit tests: one per rule/mode plus a determinism/totality grid. E3c also accepts a server highlight without a notification (accepted superset of UNREAD_STATE E3c).
  Not wired yet: `localIntent` (needs `read_intent` persistence), `latestEvent` (the adapter doesn't read it yet), `unconfirmedNotified` (needs `notification_record`); those inputs are optional and default to none.
- `RoomSummary.read` (adapter: `RoomInfo` counts + effective `NotificationSettings` mode; unknown mode → all messages); `RoomListCoordinator.readStates()`; `BadgeCoordinator` (first evaluation always writes so an
  extension-added room can be cleared); `BadgePort` (+`FakeBadgePort`), `SystemBadge` (sets `setBadgeCount` and stores the attention set in the App Group), `AttentionCache`. NSE: after a fetched notifying event
  it adds the room to the cached set and sets `badge` to the set size (a fallback per V-NSE-2; no payload count is used, ADR-0015 holds). The app requests `.badge` authorisation too.
- **Finding (on the phone, Badges enabled, authorisation granted, `setBadgeCount` succeeded): the badge stays empty because the policy computes 0 rooms.** Cause: Synapse 1.165's *native sliding sync returns constant 0* for
  `notification_count`/`highlight_count` (source: `handlers/sliding_sync/__init__.py:1522`, "dummy values"; live request confirmed), although classic `/v3/sync` gave 24 and `event_push_summary` holds 24 for the same room.
  The SDK's local counts were 0 too (room list sync carries only the newest event). So UNREAD_STATE rules E2 ("server zero ⇒ read") and E3a ("unencrypted: server counts") rest on a false premise for this stack: logged as
  V-RS-7 (falsified). **Founder decision (2026-11-19): pushes + SDK counts.** Implemented: `NotificationRecord`/`NotificationRecordPort` (+`FakeNotificationRecords`, `NotificationRecordStore` in the App Group `UserDefaults`
  with a Darwin notification, de-duplicated by event ID, 7-day/200-record limit; replaced by a GRDB table with the M3 unread persistence). The extension writes a record per fetched notifying event (time and
  mention flag from the fetched event) and sets `badge` to |app's last attention set ∪ rooms with records|. `BadgeCoordinator` now evaluates the room list's read inputs *with* the records (rule E4) plus rooms that
  only have records, and writes the union; the app's first evaluation no longer wipes the extension's rooms. Opening a room (`TimelineCoordinator(records:)`) clears that room's records, and `SystemBadge` removes
  delivered notifications whose `threadIdentifier` room no longer needs attention. SDK counts are still used where the SDK has them (they are 0 until it has the events). Not built: clearing when read on another
  device (no receipts are sent or read yet), paging all rooms, the larger-timeline-limit experiment.
- Checked: prepush passes (Domain 17, Application 50, Platform 7, adapter tests). **Verified on the founder's iPhone 16 (2026-11-19): with Halo in the background, a message from a second account made the icon show 1; opening the room cleared it.** Not yet verified: several rooms, a mention, a duplicate push, the app in the foreground, a muted room. Debug builds write `Documents/badge-debug.txt` (computed rooms, authorisation, `setBadgeCount` result). **Note: notification permission was first requested without `.badge`, so on the
  founder's phone Badges must be enabled in Settings → Notifications → Halo (or the app reinstalled).** Limits: only the loaded room-list page counts toward the badge (first 50 rooms); invites count as attention;
  `AC-U*`/G-UNREAD scenarios (S01–S22) and the auditor are not built; clearing delivered notifications when read elsewhere is not built.

**2026-11-19 (latest+14) — NSE spike: fetch + decrypt + content, with metrics**
- `NotificationFetchPort` (domain) + `MatrixNotificationPort` (adapter: `NotificationClient` in `MultipleProcesses` mode; `NotificationMapper`: DM → sender as title, group → room title and "Sender: text",
  encrypted → "Encrypted message", filtered/redacted → suppressed, not found → `.notFound`). `MatrixSessionPort` gained `sendsMessages` and `lightweightRuntime` (the NSE uses `sendsMessages: false`,
  lightweight runtime per V-NSE-3, holder name "nse"). `HaloPlatform.HaloShared` (namespace, shared Keychain access group on device builds, App Group store directory) now used by both the app and the NSE;
  Info keys `HaloNamespace`/`HaloKeychainAccessGroup`. (On a signed build, Keychain items written without a group already live in the first entitlement group, i.e. the shared one, so no re-sign-in was needed.)
- `ios/NotificationService`: reads the session from the Keychain, restores a client, fetches the event, rewrites title/body/thread id, delivers; on error or `serviceExtensionTimeWillExpire` delivers the
  generic payload content; never sets a badge. `NSEMetrics` appends one JSON line per push (`outcome`, step durations, `phys_footprint` MB, no content) to `nse-metrics.jsonl` in the App Group container.
- Checked: prepush passes (adapter tests incl. mapper tests; app and NSE build signed for the device). **First on-device run (iPhone 16, Debug build, APNs sandbox, unencrypted room, app in foreground/background mix,
  signed-in session was picked up from the shared Keychain without signing in again): 21 of 21 pushes → outcome `display`; `didReceive` → handler: median 248 ms, p95 316 ms, max 328 ms (restore ≈120 ms,
  fetch ≈100 ms); footprint median 4.6 MB, max 5.8 MB.** Caveats: the footprint is sampled when the line is written (near the end of the run), not a true peak, and it looks low for the Rust SDK — treat it as
  unverified until sampled during the fetch and compared with the extension's real limit; the room is not encrypted (decryption/UTD in the NSE untested); no timeout/termination injection (AC-NSE-3/4), no
  100-push run, no cold-device or poor-network run; a Debug build, not Release. The metrics file is copied into the app's Documents at launch in DEBUG builds so
  `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier one.mbm.halo --source Documents/nse-metrics.jsonl …` can read it (the App Group container itself is not readable from the Mac).
  No badge appears on the icon (not implemented; see below). Not implemented: `notification_record` de-duplication, read-state suppression, badge
  recomputation (`BadgeCalculator`), communication-notification intents, suppression entitlement (V-PUSH-3), sender avatars.

**2026-11-19 (latest+13) — Push groundwork: Sygnal in infra/dev, pusher registration**
- `infra/dev`: optional Sygnal v0.15.1 (`--profile push`, config rendered by `infra/dev/sygnal-config.sh` from `sygnal/sygnal.yaml.template`, needs `HALO_APNS_TEAM_ID` and one `secrets/AuthKey_<KEYID>.p8`, both
  gitignored/never committed; app id `one.mbm.halo.dev`, topic `one.mbm.halo`, APNs *sandbox*). Synapse whitelists private ranges for outbound pushes (`ip_range_whitelist`). Sygnal starts and loads the key; no push has been sent.
- `PushPort` (+`FakePushPort`), `PushCoordinator` (registers when there is a token and a ready session; refreshes on token change; retries on the next trigger), `MatrixPushPort` (`set_pusher`, HTTP,
  `event_id_only`, hex token as pushkey, generic default payload with `mutable-content` and no badge). App: `PushDelegate` receives the token, permission is requested after sign-in, `aps-environment` entitlement
  from `HALO_APS_ENVIRONMENT`, `HaloPushAppID`/`HaloPushGatewayURL` Info keys (empty gateway in Beta/Release = push off). Debug gateway URL `http://sygnal:5000/_matrix/push/v1/notify` is what Synapse (in Docker) calls.
  Checked: prepush passes (Application 45 tests, adapter compiles incl. a payload test); the signed Debug build has the `aps-environment` entitlement and the Info keys. NOT verified: the permission prompt, a pusher row
  in Synapse (none yet: the phone hasn't signed in with this build), Synapse → Sygnal → APNs → phone delivery, `delete_pusher` on logout (not implemented), the NSE (still pass-through), G-NSE.
- Verified afterwards on the device (iPhone 16, Debug build, `contract`): the pusher row appears in Synapse after sign-in (HTTP, `event_id_only`, our default payload). A message from a second account made
  Synapse call Sygnal and Sygnal send to APNs sandbox: APNs accepted it (no rejection logged). Two fixes were needed in `infra/dev`: Synapse must be *restarted* after the `ip_range_whitelist` change, and Sygnal needs
  `convert_device_token_to_hex: false` because Halo registers the hex token (the default expects base64; otherwise APNs answered 400 BadDeviceToken and Synapse deleted the pusher). Whether the notification
  actually appeared on the phone: **confirmed by the founder (2026-11-19): the generic "New message" alert shows on the lock screen** (physical iPhone 16, APNs sandbox, Debug build). No badge number appears
  on the icon — expected: pushes never set `aps.badge` (ADR-0015) and the badge comes only from the app/NSE via `BadgeCalculator`, which doesn't exist yet. First end-to-end proof of Synapse → Sygnal → APNs → device.

**2026-11-19 (latest+12) — M2: emoji picker for reactions**
- Long-press menu gains "More reactions…": a sheet with a fixed grid of 48 emoji (`TimelineViewModel.pickerEmoji`; the quick row stays 👍 ❤️ 😂). `beginReactionPicker/pickReaction`, unconfirmed rows can't open it.
  Checked: prepush passes (FeatureTimeline 18 tests); verified in the simulator against infra/dev: menu → sheet → 🎉 → chip "🎉 1" on the image message. It's a curated list, not a searchable system picker
  and has no skin tones or recents; custom/sticker reactions aren't offered.
- Not done: offline/kill-relaunch send (AC-M1), media sending, mentions, quote tap-to-jump, video/audio/file display, QR/emoji verification, G-NSE.

**2026-11-19 (latest+11) — Q-XCODEGEN resolved; first physical-device run**
- Founder decision: adopt XcodeGen. `ios/project.yml` is now in the repo (ADR-0017; Q-XCODEGEN resolved; DEVELOPMENT_SETUP updated). The generated project is committed. The development
  team is not in the spec: pass `DEVELOPMENT_TEAM=<id>` (Xcode had written one into the project; regeneration drops it).
- Device: iPhone 16 (physical, connected). `xcodebuild -project ios/Halo.xcodeproj -scheme Halo-Debug -destination 'id=<udid>' DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates build` succeeds with the
  Apple Development identity (this registers the app IDs/capabilities in the founder's developer account); `devicectl device install app` + `process launch one.mbm.halo` installed and launched
  it; the process stays running and the NSE is embedded. NOT verified: what the screen shows (no screenshot tool for the device), Keychain access group / app group at runtime, sign-in,
  and anything about pushes. The dev Synapse listens on 127.0.0.1 only and Debug.xcconfig points at 127.0.0.1, so signing in from the phone needs Synapse exposed on the LAN (and an ATS
  exception for http) — not done.
- Signing in from the phone is now possible: `HALO_DEV_BIND=0.0.0.0 docker compose -f infra/dev/docker-compose.yml up -d synapse` (done; the dev server is reachable on the LAN, so it must only
  run on a trusted network) and enter `http://<mac-lan-ip>:8008` in the Server field. Debug builds only carry `App/Info-Debug.plist` (`NSAllowsLocalNetworking` + the local-network usage text);
  Beta/Release keep ATS fully on. Not yet tried by a person on the device.
- G-NSE still open: needs a push path (Sygnal + APNs key) to measure the NSE budget on this device.

**2026-11-19 (latest+10) — M2: formatted-body rendering**
- `TimelineEvent.formattedBody` (the sender's HTML, untouched), mapped from the SDK's `TextMessageContent.formatted` (HTML only). `FeatureTimeline/HTMLText` renders a fixed subset to
  `AttributedString`: b/strong, i/em, s/del/strike, code, a (http, https, mailto, matrix only), br, p/div/pre/blockquote/headings as line breaks, ul/ol/li as bullets, `mx-reply` dropped,
  other tags dropped but their text kept, entities decoded; nothing is executed or fetched. Rows carry `styled`; edits keep the "(edited)" suffix.
  Checked: prepush passes (FeatureTimeline 17 tests incl. 5 new HTML and VM ones); adapter 16 tests pass vs infra/dev (the mapper change compiles and runs, but no contract sends or reads a
  formatted message yet). Verified in the simulator (iPhone 17, infra/dev): `Hello **bold** and _italic_ with `code`` shows bold and italic; the quoted original shows above replies made by the adapter contract.
  Fixed afterwards: `code` spans now get an explicit monospaced font (unit-tested; not re-checked on screen). Typing line and the Reply menu/composer bar not tapped through by hand.
- Not done: pills/mentions, tables, images in HTML, underline/colour, a full emoji picker, offline/kill-relaunch send (AC-M1), media sending, quote tap-to-jump.

**2026-11-19 (latest+9) — M2: typing indicators**
- `TimelineSession.typingUsers()` (others only; latest wins) and `setTyping(_:)`; `FakeTimelinePort.setTypingUsers/typingCalls`; `TimelineCoordinator.setTyping` (`true` throttled to one per 4 s via an
  injected clock, `false` only after a `true`, a `false` is sent on close) and `Snapshot.typing`; adapter via `room.subscribeToTypingNotifications` / `typingNotice` (own user filtered out);
  `FeatureTimeline`: "Alice is typing…" above the composer (names from timeline senders, user ID as fallback, "Several people…" for 3+); typing is sent from the draft's `didSet` (not while editing).
  Checked: prepush passes (Application 43, FeatureTimeline 12); adapter 16 tests pass vs infra/dev, whose contract only checks that `setTyping` is accepted. NOT verified: another user's
  typing appearing within 2 s (AC-M3) — needs a second live account/client; not looked at in the simulator.
- Not done: a full emoji picker, offline/kill-relaunch send (AC-M1), media sending, quote tap-to-jump.

**2026-11-19 (latest+8) — M2: replies**
- `ReplyPreview` (eventID, senderName, snippet?) on `TimelineEvent.replyTo`; `TimelineSession.reply(to:text:)` (confirmed events; blank → `invalidInput("EMPTY_MESSAGE")`, unknown → `.notFound`);
  `FakeTimelinePort` quotes the original text; `verifyInteractions` now also sends a reply and checks it quotes the original; `TimelineCoordinator.reply`; adapter via `timeline.sendReply`,
  `TimelineMapper.replyPreview` (text/notice/emote/media body as snippet, `nil` when the original isn't loaded or isn't text-like). `FeatureTimeline`: "Reply" in the long-press menu,
  "Replying to …" bar in the composer, quoted block above a reply ("Original message unavailable" when there's no snippet).
  Checked: `scripts/prepush.sh` passes (FeatureTimeline 11 tests, new reply test); adapter 16 tests pass vs infra/dev incl. the reply contract. Not looked at in the simulator.
- Not done: a full emoji picker, formatted-body rendering, typing indicators, offline/kill-relaunch send (AC-M1), media sending, tapping a quote to jump to the original.

**2026-11-19 (latest+7) — M2: reactions, edit, delete**
- `ReactionSummary` on `TimelineEvent`; `TimelineSession.toggleReaction(on:key:)`, `edit(event:newText:)`, `delete(event:)` (confirmed events only, by `EventID`); `FakeTimelinePort` implements them
  with distinct event IDs; `TimelinePortContract.verifyInteractions` (send → react → un-react → blank edit rejected → edit → delete); `TimelineCoordinator` methods; adapter via `timeline.toggleReaction/edit/redactEvent`,
  `TimelineMapper` now takes the own user ID (reactedByMe) and `MatrixSessionPort.ownUserID()`. `FeatureTimeline`: reaction chips, long-press menu (👍 ❤️ 😂, Edit/Delete for own), edit mode in the composer.
  Adapter 16 tests pass vs infra/dev (contract includes interactions); Application 42; verified in the simulator (menu, 👍 chip). Edit and delete from the UI were not tapped through by hand; covered by VM tests + the adapter contract.
- Not done: replies, a full emoji picker, formatted-body rendering, typing indicators.

**2026-11-19 (earlier sessions, condensed — details in `git log` and the docs they link)**
- M0a/M0b: docs review and founder decisions, `infra/dev` (Synapse + Postgres), `HaloFoundation`/`Domain`/`TestSupport`/`Application`/`Platform`/`MatrixAdapter` packages, `FeatureAuth`/`FeatureRoomList`,
  the Halo app and NSE targets, ports with fakes and shared contract suites that also run against the real adapter on `infra/dev`. Exit criterion (login → room count, session restore) verified on the simulator.
- M1: read-only timeline (lossless diffs, `ListReducer`, back-pagination with the `timelineStart` item as the start signal), sync lifecycle (`SyncCoordinator`, backoff with an injected sleeper), `HaloPersistence`
  (GRDB, V-SQL-1 resolved), inline images (`MediaPort`, `MediaLoader`), recovery-key verification (`EncryptionPort`; a hidden banner's `.task` never runs, so models start from `HaloApp`), UTD reasons.
- M2 so far: sending with local echo (send queues enabled after login/restore), reactions, edit, delete, replies, typing, HTML-subset rendering, emoji picker (entries above).
- Operational notes kept from those sessions:
  - Adapter tests need the iOS simulator (`xcodebuild -scheme HaloMatrixAdapter -destination 'platform=iOS Simulator,name=iPhone 17' test`): the SDK xcframework has no macOS slice. Contract tests need
    `TEST_RUNNER_HALO_DEV_SERVER/USER/PASSWORD/ROOMS=3/TIMELINE_ROOM` (plus `HALO_DEV_E2EE_USER/PASSWORD/KEY_OUT` for the encryption test); they are `.serialized` (parallel runs hung, cause not investigated).
  - Unsigned simulator builds need the ad-hoc signed build command (DEVELOPMENT_SETUP §3) or Keychain fails with -34018.
  - GRDB's full clone stalls here: a shallow mirror in `/tmp/grdb-mirror.git` plus a user-level `~/.swiftpm/configuration/mirrors.json` (recreate if `/tmp` is cleaned). `xcodebuild` on the app project ignores
    that mirror and can stall or fail on first resolve; retrying works.
  - A synced room holds only its newest event; pagination reports "more" once more before the start; a wrong password is `M_FORBIDDEN` mapped to `unauthorized(soft: false)` for login only.
  - Not done from M1/M2: video/audio/file display, QR/emoji verification, offline/kill-relaunch send (AC-M1), media sending, mentions, quote tap-to-jump, a real UTD turning into text (AC-E2EE-3).

## 3. Key decisions
Full list: docs/DECISION_LOG.md (D1–D67), docs/adr/ (ADR-0001…0016, all accepted).
- **D63** namespace root `one.mbm.halo` for every identifier (table: docs/development/DEVELOPMENT_SETUP.md §3).
- **D64** M0 uses Synapse's native password login; MAS from M5.
- **D65 / ADR-0015** pushes are hints, never truth; no push may set `aps.badge`; Halo's Sygnal pushkin converts count-only pushes
  into background pushes (relay only as fallback).
- **D66 / ADR-0016** gate G-NSE at the end of M1 with AC-NSE-1…6 (docs/features/NOTIFICATIONS.md §11).
- **D67** this Session Handoff Rule.
- **D47** read state: `readPosTs` (true read position) is separate from `notifiedThroughTs` (notification coverage).

## 4. Modified files (this push)
- New: `ios/Packages/Features/{FeatureAuth,FeatureRoomList,FeatureTimeline}`, timeline files in HaloDomain/TestSupport/Application/HaloMatrixAdapter, `ios/App/AppRoot.swift`, `ios/Packages/HaloPlatform`; `ios/Halo.xcodeproj`, `ios/App/`, `ios/NotificationService/`, `ios/Config/`; `ios/Packages/HaloMatrixAdapter/` (Package.swift, ErrorMapper, Bootstrap, MatrixSessionPort, MatrixRoomListPort, unit + gated contract tests).
- Docs: `docs/OPEN_QUESTIONS.md` (V-CI-2), `docs/development/DEVELOPMENT_SETUP.md` §2, `docs/ROADMAP.md`, `HANDOFF.md`.

## 5. Outstanding issues
- Parallel contract tests against one account hang (suite is serialized as a workaround; cause unknown).
- The shared Keychain access group, app-group container and a signed device build are untested (simulator, ad-hoc signing only).
- Contract tests are env-gated and are reported as skipped (not passed) without a homeserver; `prepush.sh` doesn't build/test the adapter.
- Docker CLI on this Mac hangs on the `osxkeychain` credential helper (image pulls fail with "error getting credentials"). Workaround used: a throwaway `DOCKER_CONFIG` plus a stub `docker-credential-osxkeychain` first in PATH; the user's config was not touched. Native Synapse via pip doesn't load on macOS 27. `prepush.sh` doesn't build/test the adapter (needs xcodebuild).
- `RefreshDelegate.saveSessionInKeychain` uses `try?` when encoding a refreshed session (no logger yet); add `HaloLog` + a test when HaloPlatform lands.
- Sync service is started on first room-list use and stopped only at logout (no lifecycle owner yet).
- PR #1 CI results haven't been checked yet — first task of the next session.
- Not yet run anywhere: Xcode/simulator builds, the adapter contract tests, SwiftLint (no `.swiftlint.yml` yet).
- Open validation items for M0b: V-CI-2 (Xcode Swift version = CI 6.2?), V-SQL-1, V-APPLE-1. For M1: V-NSE-*, V-PUSH-1/3/5, V-RS-1/5.
- Synapse advertises spec versions only up to v1.17 (SOURCES F-SYN-2); relevant to sticker interop (risk COMPAT-2), not to M0.
- Docker Hub rate-limited pulls in the last session (Sygnal image not pulled; Swift 6.3 tag unchecked).

## 6. Next steps
0. Receipts: set file protection on halo.sqlite, read `ownReceipt` (V-RS-1) and feed it into the policy (V-RS-1) and feed `localIntent`/`latestEvent` into `ReadStatePolicy`, confirmation rules, true ≥ 50 % visibility, mark as read/unread in the room list.
1. Push this branch / open a PR; check CI.
2. (Done) contracts pass on infra/dev. Keep running them after every adapter change.
3. Verify the badge on the phone (enable Badges for Halo in iOS Settings first), then G-NSE hardening: true peak memory, an encrypted room (decrypt/UTD in the NSE), timeout and termination injection (AC-NSE-3/4), 100 pushes, Release build.
4. Unread engine (M3): `read_intent`/`notification_record` persistence, `latestEvent`, clearing delivered notifications when read elsewhere, the scenario tests S01–S22, paging all rooms for the badge, `delete_pusher` on logout.
5. M2 left: offline send test (AC-M1), media sending, mentions. M1 left: video/audio/file display, QR/emoji verification. A push gateway for Beta/Release (the Debug one is Sygnal in `infra/dev`).

## 7. Next Session Prompt
```text
Continue development of Halo (repository evan1ee/halo).

1. Read AGENTS.md completely, then HANDOFF.md (sections 1–6). Run scripts/install-hooks.sh once.
   Trust HANDOFF.md for the project state; read other docs only as the task needs them.
2. Branch claude/m0b-adapter-scaffold: push/open PR if not done; check CI. Adapter code exists; run its contract tests against infra/dev first.
3. Then do HANDOFF.md section 6 "Next steps":
   - On a Mac with Xcode for the iOS 26 SDK: finish M0 (M0b) in the order listed there. Key references:
     docs/matrix/PORTS_CONTRACT.md, docs/matrix/SDK_INTEGRATION.md, docs/development/DEVELOPMENT_SETUP.md §3,
     ios/SDKVERSION.md (verify every SDK API at commit b93751e; never invent names).
   - Without a Mac: V-APPLE-1, then Halo's Sygnal pushkin (ADR-0015). Don't start the Xcode project or
     the adapter, and don't write code you can't compile and test.
4. Follow AGENTS.md exactly: run the checks (scripts/prepush.sh) and report real output; say what you
   couldn't run; tests for every behaviour change; Conventional Commits; docs in the same commit;
   don't decide open questions silently.
5. Before every git push (AGENTS.md §18): update HANDOFF.md (all 7 sections, this prompt included),
   bring ROADMAP/OPEN_QUESTIONS/specs up to date, and include HANDOFF.md in the last commit of the push.
```
