# Sources and Verified Facts

Every **[VERIFIED]** statement in the documentation points here. Verification date: **2026-11-19** (F-FFI-21/22 and F-PUSH-* added in the Phase 0 review, same date and revisions).
Re-verify at every SDK bump (see [development/BUILD_AND_RELEASE.md](development/BUILD_AND_RELEASE.md)).

## Pinned references

| Item | Value | How verified |
|---|---|---|
| matrix-rust-sdk | `b93751e93da6949a6a8ef8ff0b2c1c8faacaf677` (2026-11-16) — the commit the prebuilt `26.11.17` ships (V-SDK-1, `ios/SDKVERSION.md`); crate version 0.19.1, `rust-version = "1.96"`. Facts were first collected at `7ff8855` (2026-11-18) and re-checked at `b93751e`: every F-FFI name exists there and the licence inventory is identical | Git checkout of https://github.com/matrix-org/matrix-rust-sdk |
| Prebuilt Swift package | `element-hq/matrix-rust-components-swift`, release `26.11.17` (checksum `d4d202da…6263`, built from SDK `b93751e` per its release commit), product `MatrixRustSDK` (dynamic library), binary target `MatrixSDKFFI.xcframework` | `Package.swift` at https://github.com/element-hq/matrix-rust-components-swift |
| UniFFI | Workspace pins `0.32.1`; crates.io latest stable `0.32.2` | SDK `Cargo.toml`; crates.io API |
| ruma (used by the SDK) | 0.17.2 git rev `5133d4ec` | SDK `Cargo.lock` |
| Matrix spec | Latest release **v1.19** | Tags of https://github.com/matrix-org/matrix-spec |
| Synapse | Latest tag v1.165.0 | Tags of https://github.com/element-hq/synapse |
| Matrix Authentication Service (MAS) | Pinned tag v1.29.0 (`ghcr.io/element-hq/matrix-authentication-service:1.29.0`) | Tags of https://github.com/element-hq/matrix-authentication-service (`mas-cli v1.29.0`) |
| Sygnal | Latest tag v0.15.1 | Tags of https://github.com/matrix-org/sygnal |
| GRDB.swift | v7.12.0, MIT | https://github.com/groue/GRDB.swift (LICENSE) |
| Synapse push code | tag `v1.165.0`, `synapse/push/httppusher.py`, `synapse/push/push_tools.py`, `synapse/config/push.py` | Sparse checkout of https://github.com/element-hq/synapse |
| Sygnal APNs pushkin | tag `v0.15.1`, `sygnal/apnspushkin.py`, `sygnal/sygnal.py` | Git checkout of https://github.com/matrix-org/sygnal |

## Verified facts

### F-LIC — licences
- F-LIC-1 matrix-rust-sdk is Apache-2.0 (root `LICENSE`); `bindings/matrix-sdk-ffi/Cargo.toml` declares `license = "Apache-2.0"`, `publish = false`.
- F-LIC-2 The iOS dependency tree of `matrix-sdk-ffi` (`cargo metadata --filter-platform aarch64-apple-ios`, normal + build deps) has 552 crates with default features and **564 with `--features sentry`** — the feature set the upstream Swift build uses (`FFI_FEATURES = "sentry"` in `xtask/src/swift.rs`); the 12 extra crates are MIT/Apache-2.0. **No GPL/LGPL/AGPL** in either. MPL-2.0: `uniffi*`, `eyeball-im`, `imbl`, `imbl-sized-chunks`. Counts include `matrix-sdk-ffi` itself. Full list: [security/inventory/rust-deps-matrix-sdk-ffi.csv](security/inventory/rust-deps-matrix-sdk-ffi.csv), generated and checked by `scripts/rust-license-inventory.py`.
- F-LIC-3 Element X iOS: `LICENSE` = AGPL-3.0, plus `LICENSE-COMMERCIAL` (https://github.com/element-hq/element-x-ios). Only these two files were opened.
- F-LIC-4 `matrix-rust-components-swift` is Apache-2.0.
- F-LIC-5 GRDB.swift is MIT.
- F-LIC-6 evan1ee/matrix-bot is MIT.
- F-LIC-8 Server components (not distributed): Synapse `LICENSE-AGPL-3.0` (element-hq/synapse), MAS `LICENSE` AGPL-3.0, Sygnal `LICENSE` Apache-2.0.
- F-LIC-7 Build/test tools: swift-snapshot-testing (MIT), SwiftLint (MIT), gitleaks (MIT), cargo-deny and cargo-about (MIT / Apache-2.0 dual) — LICENSE files on each default branch.

### F-FFI — matrix-sdk-ffi (at the pinned rev)
- F-FFI-1 `crate-type = ["cdylib", "staticlib", "lib"]`; default features include `bundled-sqlite`, `experimental-search`, `rustls-aws-lc-rs`.
- F-FFI-2 It uses `uniffi::include_scaffolding!("api")` (a UDL file) plus proc-macros. The upstream build is `cargo xtask swift build-framework` (`xtask/src/swift.rs`), producing `MatrixSDKFFI.xcframework` via `uniffi-bindgen generate --library`.
- F-FFI-3 The wrapped SDK objects are `pub(crate)` (`Client.inner`, `Timeline.inner`, `SyncService.inner`), so **another crate can't extend the upstream FFI objects** (basis for D44).
- F-FFI-4 Client APIs that exist: `ClientBuilder::{homeserver_url, server_name_or_homeserver_url, session_paths, sqlite_store, sliding_sync_version_builder, cross_process_lock_config, set_session_delegate, system_is_memory_constrained, threads_enabled, build}`; `Client::{login, url_for_oauth, login_with_oauth_callback, restore_session, session, logout, sync_service, notification_client, encryption, get_room, rooms, set_pusher, delete_pusher, account_data, set_account_data, observe_account_data_event, observe_room_account_data_event, upload_media, get_media_content, get_media_thumbnail, get_media_file, total_unread_notifications, mark_all_rooms_as_read, search_users, get_profile, ignore_user}`.
- F-FFI-5 Sync: `SyncService::{start, stop, state, room_list_service}`, `SyncServiceBuilder::{with_offline_mode, with_share_pos, finish}`. Room list: `RoomListService::{all_rooms, state, sync_indicator, set_room_subscriptions}`, `RoomList::{loading_state, entries_with_dynamic_adapters}`, `RoomListDynamicEntriesController::{set_filter, add_one_page, reset_to_one_page}`.
- F-FFI-6 Read state on `Room`: `send_single_receipt(receipt_type, thread, event_id)`, `mark_as_fully_read_unchecked(event_id)`, `load_user_receipt(receipt_type, thread, user_id)`, `set_unread_flag(bool)`, `mark_as_read(receipt_type)`, `subscribe_to_room_info_updates`, `typing_notice`, `subscribe_to_typing_notifications`. `ReceiptType = Read | ReadPrivate | FullyRead`.
- F-FFI-7 `RoomInfo` contains `notification_count`, `highlight_count` (server), `num_unread_messages`, `num_unread_notifications`, `num_unread_mentions` (client-computed), `is_marked_unread`.
- F-FFI-8 Timeline: `add_listener` (`TimelineListener::on_update(Vec<TimelineDiff>)`), `paginate_backwards`, `send`, `send_reply`, `edit`, `redact_event`, `toggle_reaction`, `send_image/video/audio/file`, `send_read_receipt`, `mark_as_read`, `retry_send`, `abort_send`, `retry_decryption`. The message kind includes `Sticker { body, info, source }`.
- F-FFI-9 There's no dedicated sticker send API. `Room::send_raw(event_type, content)` sends arbitrary message events; `Room::send_state_event_raw` sends arbitrary state; `Room::state_events(type)` reads state, but **only types included in the sliding sync `required_state` are stored locally** (doc comment), so custom types are empty otherwise.
- F-FFI-10 Notifications: `NotificationClient::{get_notification, get_notifications}`; `NotificationStatus = Event | EventNotFound | EventFilteredOut | EventRedacted`; `NotificationItem` includes `is_noisy`, `has_mention`, `thread_id`, `sender_info`, `room_info`, `raw_event`. `NotificationProcessSetup = MultipleProcesses | SingleProcess`. `CrossProcessLockConfig = MultiProcess { holder_name } | SingleProcess`.
- F-FFI-11 `SearchService` exists (`set_query`, `paginate`, `subscribe_to_results`), backed by `matrix-sdk-search` (Tantivy 0.27, encrypted index).
- F-FFI-13 Platform setup: `init_platform(config: TracingConfiguration, use_lightweight_tokio_runtime: bool)` (once per process; errors if the logger is already initialised); `TracingConfiguration { log_level, trace_log_packs, extra_targets, write_to_stdout_or_system, write_to_files, sentry_config }`; also `reload_tracing_file_writer`, `enable_sentry_logging` (`platform/mod.rs`).
- F-FFI-14 `Client::clear_caches`, `Client::get_store_sizes`, `Client::optimize_stores` exist.
- F-FFI-15 `Room.latest_event()` returns `LatestEventValue = None | Remote{timestamp, sender, is_own, profile, content} | RemoteInvite{…} | Local{…}` (no event id); `Timeline.latest_event_id()` exists. `UserReceipt{event_id, receipt: Receipt{timestamp?}}` where the timestamp is the receipt's.
- F-FFI-16 Pushers: `PusherIdentifiers{pushkey, app_id}`, `PusherKind = Http{data: HttpPusherData{url, format: PushFormat?, default_payload: String?}} | Email`, `PushFormat = EventIdOnly`.
- F-FFI-17 `SyncServiceState = Idle | Running | Terminated | Error | Offline`; `SqliteStoreBuilder::new(data_path, cache_path)` with `.passphrase(Option<String>)`, `.key(Option<Vec<u8>>)`, `.system_is_memory_constrained()`; `SlidingSyncVersionBuilder = None | Native | DiscoverNative`; the Apple release profile `small-release-stripped` = release + `opt-level = "s"`, `lto = true`, `strip = "debuginfo"` (no panic override).
- F-FFI-18 Further FFI names that exist (signatures to confirm when used): `ClientBuilder::{auto_enable_cross_signing, auto_enable_backups, room_key_recipient_strategy, backup_download_strategy, disable_ssl_verification}`; `Client::{get_session_verification_controller, create_room, get_dm_room, get_dm_rooms, join_room_by_id, join_room_by_id_or_alias, get_room_preview_from_room_id, account_url, homeserver_login_details, get_notification_settings, get_media_preview_display_policy, set_media_retention_policy, get_max_media_upload_size, get_url_preview, ignored_users, unignore_user, display_name, set_display_name, avatar_url, upload_avatar, remove_avatar, subscribe_to_own_profile, enable_all_send_queues}`; `Room::{set_is_favourite, get_power_levels, subscribe_to_identity_status_changes, withdraw_verification_and_resend, ignore_device_trust_and_resend}`; types `RoomListEntriesDynamicFilterKind`, `RoomMembersIterator`, `ComposerDraft`.
- F-FFI-19 `matrix-rust-components-swift` `Package.swift`: `platforms: [.iOS(.v16)]`, product `MatrixRustSDK` `type: .dynamic`, binary target `MatrixSDKFFI` downloaded by URL + checksum.
- F-FFI-20 UniFFI: the SDK workspace pins `uniffi = "0.32.1"`; crates.io latest stable is `0.32.2`.
- F-FFI-21 Runtime and subscriptions: async work in the bindings runs on a tokio runtime the crate obtains itself (`runtime.rs`
  `get_runtime_handle`, via `async_compat`), so the app creates none. Subscriptions return `TaskHandle` (`task_handle.rs`) with
  `cancel()` (aborts the task) and `is_finished()`; dropping the handle also cancels it.
- F-FFI-22 Further names that exist (found during the Phase 0 review; signatures to confirm when used): `ClientBuilder::server_name_from_user_id`;
  `Client::{restore_session_with, abort_oauth_auth, subscribe_to_send_queue_updates}`; `Room::{timeline_with_configuration,
  subscribe_to_send_queue_updates}`; `Timeline::{subscribe_to_back_pagination_status, load_reply_details, edit_revisions}`; record
  `MediaUploadProgress` (`timeline/mod.rs`; how `send_image` reports it is confirmed at M2); `MsgLikeKind::Sticker { body, info, source }`
  (`timeline/msg_like.rs`); `TimelineFocus = Live{…} | Event{event_id, num_context_events, thread_mode} | Thread{…} | PinnedEvents`
  (`timeline/configuration.rs`).
- F-FFI-12 The doc comment of `Client::mark_all_rooms_as_read` refers to wrong iOS badges caused by the backend: https://github.com/element-hq/element-x-ios/issues/3151.
- F-FFI-23 Verified gaps in pinned `matrix-rust-components-swift` `26.11.17` (`matrix_sdk_ffi.swift`, 2026-11-21): (a) `SyncSettingsV2` exposes only `timeoutMs: UInt64?` and `fullState: Bool` — no classic-sync filter / `lazy_load_members` parameter (R-18); (b) `Timeline` exposes no `sendRaw` / `sendSticker` / custom event method (`send` accepts only `RoomMessageEventContentWithoutRelation`, `AttachmentKind` has only `.image/.video/.audio/.voice/.file`), so `Room.sendRaw` is the only API for `m.sticker` (R-21); (c) `NotificationClient.getNotification` invokes `client.sliding_sync("notifications")` first (`notification_client.rs:688`), so the NSE's `MatrixSessionPort` must enable native sliding sync (`enablesSlidingSync: true`) even though the main app uses classic `/sync` (`.none`, D74).
- F-FFI-24 Present in pinned `26.11.17` bindings (`matrix_sdk_ffi.swift`, read 2026-11-25; signatures to confirm when used): `reportContent`, `reportRoom`, `kickUser`, `banUser`, `unbanUser`, `updatePowerLevelsForUsers`,
  `sendPollResponse`, `endPoll`, `subscribeToIdentityStatusChanges`, `withdrawVerificationAndResend`, `resetIdentity`, `TimelineFocus.event`, `loadReplyDetails`, `resolveRoomAlias`, `knock`, `getUrlPreview`, `getStoreSizes`, `clearCaches`,
  `optimizeStores`, `setIsLowPriority`, `spaceService`, `requestUserVerification`, `newLoginWithQrCodeHandler`; `EventSendState.sendingFailed` carries a `QueueWedgeError` (insecure devices, identity violations).
- F-FFI-25 Search and history, read in `matrix-rust-sdk` at `b93751e` (2026-11-25, source only): `run_search_backfill` returns at once when automatic back-pagination is off, and sweeps about 13 weeks back otherwise (`event_cache/search_backfill.rs`);
  the same queue serves latest-event resolution and read-receipt search (`latest_events/room_latest_events.rs`, `event_cache/caches/read_receipts.rs`). `search_index_store_kind` defaults to `InMemory` and room events are sent to the index task either way (`client/builder/mod.rs`,
  `event_cache/caches/room_updates.rs`). `Room::subscribe_to_message_like_events` reports sync events only, never one decrypted later (binding doc comment). Event-focused timelines start from `/context`, page in both directions, are kept in memory only and switch to a thread when the focused event is in one
  (`event_cache/caches/event_focused/mod.rs`). The bindings default `backup_download_strategy` to `AfterDecryptionFailure` (`matrix-sdk-ffi/src/client_builder.rs`). The SDK index takes text, notice, emote, location, file names and captions (`search_index/mod.rs`).
- F-FFI-26 Event-focused caches live as long as their client: `Caches.event_focused` only ever inserts (`event_cache/caches/mod.rs` at `b93751e`, 2026-11-25); measured about 0.5 KB per event (20,000 events: +10.6 MB) and flat when the client is dropped. Every live timeline opened and dropped leaves 20–25 KB in the client (measured, 1,000 rooms read repeatedly, from a settled baseline). `ClientBuilder` accepts a second client on the same data path with another cache path and lock holder; `restoreSession` there takes 0.09 s with one room loaded.
- F-FFI-27 Found by running it (2026-11-25, `b93751e`): `Room.timelineWithConfiguration` with `reportUtds: true` fails (`ClientError.Generic`) unless the client has an unable-to-decrypt hook, which Halo doesn't set (`matrix-sdk-ffi/src/room/mod.rs`); a missing focus event is `ClientError.Generic` with `EventNotFound` in its details;
  `loadOrFetchEvent` answers from the event cache first, so it doesn't know a deletion that sync left out (`crates/matrix-sdk/src/room/mod.rs`); `subscribeToMessageLikeEvents` calls its listener from a task of its own, a moment after the sync response; every handler sees every message-like event of its room and filters by type.
- F-DEV-1 Physical iPhone 16 (`iPhone17,3`, iOS 26, SQLite 3.54.0, 2026-11-21) verification against `infra/dev` Synapse 1.165.0 + Sygnal sandbox APNs: 10/10 background pushes (`8` sequential + `2` concurrent) completed in `HaloNotificationService` with `outcome = "display"`, zero timeouts, zero Jetsam/`0xdead10cc` crashes; peak `phys_footprint` = **6.2 MB** (R-09 lightweight Tokio runtime, ~26% of ~24 MB NSE limit); cold push `restoreMs = 157 ms`, `totalMs = 260 ms`; 9/9 warm pushes `restoreMs = 0 ms`, `totalMs = 44–96 ms` (R-23 `SingleFlightCache`); `halo.sqlite`, `-wal`, `-shm`, and parent directory all verified `NSFileProtectionCompleteUntilFirstUserAuthentication`; `notificationRecordsAtLaunch = 10` confirmed cross-process NSE → App GRDB `notification_record` persistence (R-13).
- F-DEV-2 Physical iPhone 16 (`iPhone17,3`, iOS 26, 2026-11-22) **100-push G-NSE soak + fault-injection + post-kill recovery** (`Halo-Debug`, `infra/dev` Synapse 1.165.0 + Sygnal sandbox APNs):
  - **100-push soak (AC-NSE-1, AC-NSE-2):** 80 steady + 4 bursts of 5 concurrent pushes; **100/100** `outcome = "display"`, 0 errors, 0 `serviceExtensionTimeWillExpire` timeouts, 0 Jetsam crashes; `phys_footprint` min **7.00 MB**, median **7.20 MB**, peak **7.40 MB** (~30.8% of ~24 MB limit, ≤ 80% threshold); `totalMs` min **21 ms**, p50 **60 ms**, p95 **144 ms**, p99/max **495 ms** (≤ 50% of 30 s budget).
  - **Fault injection (AC-NSE-5, AC-NSE-6):** 2 pushes with nonexistent `event_id` and `counts.unread = 99` sent via Sygnal completed cleanly as `outcome = "error"` (generic fallback, payload count ignored per D65) in **2,167 ms** and **2,210 ms**, **7.40 MB**, zero crashes.
  - **Extension termination recovery (AC-NSE-4):** killed both `HaloNotificationService` and `Halo`; next push cold-started cleanly (`restoreMs = 162 ms`, `fetchMs = 110 ms`, `totalMs = 277 ms`, `6.8 MB`, `outcome = "display"`), followed by warm `restoreMs = 0 ms`, `totalMs = 96 ms`, `7.0 MB`, `outcome = "display"` — zero lock contention, zero `0xdead10cc`.

### F-SDK — SDK internals
- F-SDK-1 `matrix-sdk-base/src/read_receipts.rs`: `ReadReceipts { num_unread, num_notifications, num_mentions, latest_active, pending }`; `pending` is a ring buffer of **10** receipts whose target event isn't known locally. The counts are updated by the event cache in `matrix-sdk`.
- F-SDK-3 Encrypted non-message events (verified 2026-11-21 against `infra/dev`, Synapse 1.165.0, pinned SDK `26.11.17`, `ClassicSyncEvidenceTests.encryptedNonMessageEvidence` and `tools/server-rules/check_server_rules.py`): the server counts every `m.room.encrypted` event in all-messages mode, a poll vote and an encrypted reaction included; the SDK counts after decrypting and re-evaluating the push rules: a poll vote counts nothing, a call invite counts **1 notification and 0 messages**, an event it can't decrypt counts **1 message and 1 notification**. The SDK sends reactions in plaintext (`crates/matrix-sdk/src/room/futures.rs`: "Reactions are currently famously not encrypted"), and a plaintext reaction counts nowhere. The SDK's latest event (`Room.latestEvent`) skips poll votes and undecryptable events and includes call invites (`latest_events/latest_event/builder.rs`, local checkout). `Room.markAsRead` receipts the latest event of any kind, so it clears the vote's count. After the user's own message the SDK's count goes back to 0 (an own event is an implicit receipt) while the server keeps counting; an undecryptable event after it counts 1 in the SDK.
- F-SDK-2 The SDK does not use image packs; ruma at the pinned rev provides the stable types `m.room.image_pack` (`ruma-events/src/room/image_pack.rs`) and `m.image_pack.rooms`.

### F-SPEC — Matrix specification
- F-SPEC-1 Private read receipts (`m.read.private`) and threaded receipts/notifications (MSC3771, MSC3773) were added in **v1.4**.
- F-SPEC-2 Marking rooms unread (`m.marked_unread`, MSC2867) was added in **v1.12**.
- F-SPEC-3 Image packs (`m.room.image_pack` state, `m.image_pack.rooms` account data, MSC2545) were added in **v1.19**. Shortcode grammar `^[A-Za-z0-9_-]{1,100}$`; stickers ≥ 512×512 recommended; **packs are not encrypted** and clients SHOULD warn about this in E2EE rooms; when sending a sticker, `body` = image body or shortcode and `info` = image info.
- F-SPEC-4 `m.fully_read` is room account data (read markers module); `m.mentions` (intentional mentions) were added in v1.7.
- F-SPEC-5 Simplified Sliding Sync endpoint (MSC4186, unstable): `POST /_matrix/client/unstable/org.matrix.simplified_msc3575/sync` (ruma-client-api `sync/sync_events/msc4186.rs` at the pinned rev).
- Spec text: https://spec.matrix.org/v1.19/client-server-api/ (source: https://github.com/matrix-org/matrix-spec).

### F-PUSH — Synapse and Sygnal push behaviour (at the pinned tags)
- F-PUSH-1 Synapse's HTTP pusher sends a **count-only notification** whenever the user's badge changes after a receipt
  (`on_new_receipts` → `_update_badge` → `_send_badge`): `{"notification": {"id": "", "type": null, "sender": "", "counts": {"unread": N}, "devices": [...]}}`.
  It has no event id or room id and is sent **regardless of the pusher's `format`**; MSC4076's `disable_badge_count` (experimental
  flag) removes `counts` only from *event* pushes, not from these. `N` comes from `get_badge_count`: invites + rooms with a non-zero
  notification count (`push.group_unread_count_by_room`, default `true`), or the sum of counts when that option is `false`.
- F-PUSH-2 Sygnal's APNs pushkin uses the `event_id_only` payload only when the notification has an event id and no type:
  `default_payload` merged with top-level `room_id`, `event_id`, `unread_count` (no `aps.badge`). Otherwise it builds the full
  payload: for a count-only notification (`type` null → `default_payload` **not** applied, no alert) the result is
  `{"aps": {"badge": N}}`, which iOS applies to the app icon without running the NSE or waking the app.
- F-PUSH-3 Sygnal loads a pushkin class by fully qualified name when an app's `type` contains a dot (`sygnal.py` `_make_pushkin`),
  and the APNs pushkin has a per-app `push_type` setting (`alert`, `background`, `voip`, …) applied to every push of that app.

### F-SYN — Synapse as deployed in `infra/dev` (measured 2026-11-19)
- F-SYN-1 Synapse `v1.165.0` enables native Simplified Sliding Sync by default (`experimental.msc3575_enabled` defaults to `true`) and
  advertises `org.matrix.simplified_msc3575: true` in `/_matrix/client/versions`; the endpoint requires `required_state` in every list
  (`M_MISSING_PARAM` otherwise). `infra/dev/smoke.sh` checks both.
- F-SYN-2 The same Synapse advertises spec versions up to **v1.17** (not v1.19). Image packs are ordinary state and account data, so
  this doesn't stop Halo from storing them; clients that gate image-pack support on the advertised version won't enable it (COMPAT-2).
- F-SYN-3 The generated `homeserver.yaml` binds the listener to `::`; where IPv6 is unavailable Synapse fails to start
  (`Errno 97`), so `infra/dev` overrides the listener to `0.0.0.0` inside the container.

### F-CI — toolchain checks (measured 2026-11-19)
- F-CI-1 GRDB `7.12.0` builds and its API works on Linux with `swift:6.2-noble` (Swift 6.2.4) plus `libsqlite3-dev` (system SQLite
  3.45.1): two `DatabasePool`s on one WAL file, 500 concurrent monotonic upserts (`ON CONFLICT … WHERE excluded.event_ts > …`) end at
  the maximum. In-process only — the app ⇄ NSE case is V-SQL-2.

### F-BOT — evan1ee/matrix-bot
- F-BOT-1 Matrix output is `body` + an HTML subset (`b i u code pre p ul ol li blockquote a br`, plus `del` in todo views). `Content.actions` (buttons) aren't sent on Matrix.
- F-BOT-2 Reactions 👍 done, 👎 delete, 😝 +1 day, 🎉 celebrate; only on messages registered in `reaction_targets`, which are parsed from `Added Task <b>#N</b>` and `Reminder #N set!` confirmations.
- F-BOT-4 On a processed reaction the bot reacts on the **target event** with an ack emoji (`✅` done, `🗑️` delete, `⏰` delay, `🎉` celebrate) and replies, e.g. `✅ Marked task as done: <i>"{title}"</i>`, `🗑️ Deleted task: <i>"{title}"</i>`; the reply is registered as a further reaction target (except for deletes). Reactions are processed only from the task owner (`reaction.rs`).
- F-BOT-3 Todo list format: `📋 <b>{title}:</b><br/>• [<b>#{id}</b>] {text} ...<br/>`; completed rows use `<del>…</del> ✅`.
- F-APPLE-1 (V-APPLE-1, checked 2026-11-19 against Apple's documentation JSON at `developer.apple.com/tutorials/data/documentation/…`):
  `Observation` framework is available from iOS 17.0; `UNNotificationServiceExtension` is the entry point of a notification service
  extension (iOS 10.0+); the entitlement `com.apple.developer.usernotifications.filtering` (iOS 13.3+) is added to the NSE target's
  entitlements after Apple grants it and lets the NSE suppress a notification by returning empty content; `FileProtectionType.completeUntilFirstUserAuthentication`
  keeps a file inaccessible only until the first unlock after boot; `BGTaskScheduler` (iOS 13.0+) schedules background work for a suspended app.
  **Not verified from documentation:** the NSE execution-time and memory limits (Apple publishes no numbers; measured under G-NSE, AC-NSE-1…6) and
  ImageIO animated GIF/APNG/WebP decoding (checked in M4).

### F-KLIPY — KLIPY API (verified 2026-11-23 at https://docs.klipy.com and with a live call)
- F-KLIPY-1 Base `https://api.klipy.com`; `GET api/v1/{app_key}/{gifs|stickers}/{trending|search}` with `page`, `per_page` (search 8–50, default 24), `q`, `customer_id` (stable per user), `locale` (ISO 3166 alpha-2), `content_filter` (`off|low|medium|high`), `format_filter`; response `{result, data: {data: [{id, slug, title, file: {hd|md|sm|xs: {gif|webp|jpg|mp4|webm|png: {url, width, height, size}}}, type, blur_preview}], current_page, per_page, has_next}}` (stickers carry `png` instead of `jpg`, checked live). Share trigger `POST api/v1/{app_key}/{kind}/share/{slug}` with body `{customer_id, q}`. Integration requirements: media loaded directly from returned URLs, not stored/mirrored/re-hosted/altered; requests from the end-user client; search/trending order and composition preserved; KLIPY content in its own grid; "Search KLIPY" placeholder required, "Powered by KLIPY" optional. A testing key is limited to 100 requests per hour until production access is granted in the Partner Panel. Media hosts: `static.klipy.com`, `static1.klipy.com`, `static2.klipy.com`.

## Unverified (tracked in OPEN_QUESTIONS.md)
Statements about iOS NSE memory limits, APNs/background push throttling, filtering-entitlement
approval, and SwiftUI performance are labelled **[ASSUMPTION]** until measured.
