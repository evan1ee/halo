# Sources and Verified Facts

Every **[VERIFIED]** statement in the documentation points here. Verification date: **2026-11-19**.
Re-verify at every SDK bump (see [development/BUILD_AND_RELEASE.md](development/BUILD_AND_RELEASE.md)).

## Pinned references

| Item | Value | How verified |
|---|---|---|
| matrix-rust-sdk | `7ff88556d856b6cb52fc44f14a9cb31af7799c3f` (2026-11-18), crate version 0.19.1, `rust-version = "1.96"` | Git checkout of https://github.com/matrix-org/matrix-rust-sdk |
| Prebuilt Swift package | `element-hq/matrix-rust-components-swift`, release `26.11.17`, product `MatrixRustSDK` (dynamic library), binary target `MatrixSDKFFI.xcframework` | `Package.swift` at https://github.com/element-hq/matrix-rust-components-swift |
| UniFFI | Workspace pins `0.32.1`; crates.io latest stable `0.32.2` | SDK `Cargo.toml`; crates.io API |
| ruma (used by the SDK) | 0.17.2 git rev `5133d4ec` | SDK `Cargo.lock` |
| Matrix spec | Latest release **v1.19** | Tags of https://github.com/matrix-org/matrix-spec |
| Synapse | Latest tag v1.165.0 | Tags of https://github.com/element-hq/synapse |
| Sygnal | Latest tag v0.15.1 | Tags of https://github.com/matrix-org/sygnal |
| GRDB.swift | v7.12.0, MIT | https://github.com/groue/GRDB.swift (LICENSE) |

## Verified facts

### F-LIC — licences
- F-LIC-1 matrix-rust-sdk is Apache-2.0 (root `LICENSE`); `bindings/matrix-sdk-ffi/Cargo.toml` declares `license = "Apache-2.0"`, `publish = false`.
- F-LIC-2 The iOS dependency tree of `matrix-sdk-ffi` (`cargo metadata --filter-platform aarch64-apple-ios`, normal + build deps) has 552 crates with default features and **564 with `--features sentry`** — the feature set the upstream Swift build uses (`FFI_FEATURES = "sentry"` in `xtask/src/swift.rs`); the 12 extra crates are MIT/Apache-2.0. **No GPL/LGPL/AGPL** in either. MPL-2.0: `uniffi*`, `eyeball-im`, `imbl`, `imbl-sized-chunks`. Full list: [security/inventory/rust-deps-matrix-sdk-ffi.csv](security/inventory/rust-deps-matrix-sdk-ffi.csv).
- F-LIC-3 Element X iOS: `LICENSE` = AGPL-3.0, plus `LICENSE-COMMERCIAL` (https://github.com/element-hq/element-x-ios). Only these two files were opened.
- F-LIC-4 `matrix-rust-components-swift` is Apache-2.0.
- F-LIC-5 GRDB.swift is MIT.
- F-LIC-6 evan1ee/matrix-bot is MIT.
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
- F-FFI-12 The doc comment of `Client::mark_all_rooms_as_read` refers to wrong iOS badges caused by the backend: https://github.com/element-hq/element-x-ios/issues/3151.

### F-SDK — SDK internals
- F-SDK-1 `matrix-sdk-base/src/read_receipts.rs`: `ReadReceipts { num_unread, num_notifications, num_mentions, latest_active, pending }`; `pending` is a ring buffer of **10** receipts whose target event isn't known locally. The counts are updated by the event cache in `matrix-sdk`.
- F-SDK-2 The SDK does not use image packs; ruma at the pinned rev provides the stable types `m.room.image_pack` (`ruma-events/src/room/image_pack.rs`) and `m.image_pack.rooms`.

### F-SPEC — Matrix specification
- F-SPEC-1 Private read receipts (`m.read.private`) and threaded receipts/notifications (MSC3771, MSC3773) were added in **v1.4**.
- F-SPEC-2 Marking rooms unread (`m.marked_unread`, MSC2867) was added in **v1.12**.
- F-SPEC-3 Image packs (`m.room.image_pack` state, `m.image_pack.rooms` account data, MSC2545) were added in **v1.19**. Shortcode grammar `^[A-Za-z0-9_-]{1,100}$`; stickers ≥ 512×512 recommended; **packs are not encrypted** and clients SHOULD warn about this in E2EE rooms; when sending a sticker, `body` = image body or shortcode and `info` = image info.
- F-SPEC-4 `m.fully_read` is room account data (read markers module); `m.mentions` (intentional mentions) were added in v1.7.
- Spec text: https://spec.matrix.org/v1.19/client-server-api/ (source: https://github.com/matrix-org/matrix-spec).

### F-BOT — evan1ee/matrix-bot
- F-BOT-1 Matrix output is `body` + an HTML subset (`b i u code pre p ul ol li blockquote a br`, plus `del` in todo views). `Content.actions` (buttons) aren't sent on Matrix.
- F-BOT-2 Reactions 👍 done, 👎 delete, 😝 +1 day, 🎉 celebrate; only on messages registered in `reaction_targets`, which are parsed from `Added Task <b>#N</b>` and `Reminder #N set!` confirmations.
- F-BOT-4 On a processed reaction the bot reacts on the **target event** with an ack emoji (`✅` done, `🗑️` delete, `⏰` delay, `🎉` celebrate) and replies, e.g. `✅ Marked task as done: <i>"{title}"</i>`, `🗑️ Deleted task: <i>"{title}"</i>`; the reply is registered as a further reaction target (except for deletes). Reactions are processed only from the task owner (`reaction.rs`).
- F-BOT-3 Todo list format: `📋 <b>{title}:</b><br/>• [<b>#{id}</b>] {text} ...<br/>`; completed rows use `<del>…</del> ✅`.

## Unverified (tracked in OPEN_QUESTIONS.md)
Statements about iOS NSE memory limits, APNs/background push throttling, filtering-entitlement
approval, and SwiftUI performance are labelled **[ASSUMPTION]** until measured.
