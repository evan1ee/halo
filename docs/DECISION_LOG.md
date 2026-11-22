# Decision Log

Short, numbered product and architecture decisions (Dnn). Larger decisions get an ADR in
`docs/adr/`; this log links to them. **Superseded decisions stay listed and are marked**, so
history is never rewritten. Every document cites decisions by ID.

Legend: ✅ active · ⛔ superseded (see the replacing entry)

## Product and distribution
| ID | Decision | Status |
|---|---|---|
| D1 | First 12 months: personal / small circle via TestFlight. Long term: public App Store app | ✅ |
| D2 | Private repository, proprietary ("All rights reserved") | ✅ |
| D24 | Capacity: solo developer, part-time (~10–20 h/week) | ✅ |
| D25 | Minimum iOS 26 | ✅ ADR-0014 |
| D45 | Priorities: P0 = unread/read-state correctness; P1 = core messaging; **stickers v1 stays in the MVP** (confirms D14). P2 = sticker v2, bot cards, Bot Activity tab, productivity features | ✅ |

## Matrix foundation and architecture
| ID | Decision | Status |
|---|---|---|
| D3 | Own Rust FFI crate on top of unmodified matrix-rust-sdk | ⛔ by D44 (verified: upstream FFI types can't be extended from another crate) |
| D27 | Reuse matrix-sdk-ffi bindings + own crate in one XCFramework | ⛔ by D44 |
| D44 | **Swift-first, migrate later.** Halo's domain logic is Swift. The unmodified upstream `matrix-sdk-ffi` is consumed as a binary framework. **Only `HaloMatrixAdapter` imports upstream FFI types**; it implements Halo-owned port protocols. The validation gate G-FFI (M3) decides whether to replace it with Halo-owned UniFFI bindings over `matrix-sdk`/`matrix-sdk-ui`, without changes to the domain or feature modules | ✅ ADR-0002, ADR-0003, ADR-0004 |
| D4 | Homeserver: self-hosted Synapse with native Simplified Sliding Sync (MSC4186) | ✅ |
| D15 | Auth: OIDC (MAS) + legacy password; QR/emoji verification; recovery key | ✅ |
| D41 | SwiftUI: `@Observable` feature view models, service protocols, `AsyncStream`; constructor + Environment injection | ✅ ADR-0005 |
| D40 | App-owned data in one Rust-owned encrypted SQLite | ⛔ by D46 |
| D46 | App-owned data in one Swift-owned SQLite database (GRDB, MIT) in the App Group container, file protection plus field encryption with CryptoKit for content columns | ✅ ADR-0006 |
| D42 | Monorepo (`ios/`, `infra/`, `docs/`, later `core/`) | ✅ ADR-0001 |
| D43 | Calls: keep the MatrixRTC / Element Call widget path open; MVP only renders call events | superseded by D94 |

## Unread, receipts, notifications (P0)
| ID | Decision | Status |
|---|---|---|
| D5 | App icon badge = number of rooms needing attention | ⛔ by D82 |
| D6 | Read = event actually visible in the foreground for ≥ 0.5 s | ✅ |
| D7 | Public `m.read` by default; setting for `m.read.private` | ✅ |
| D8 | Own unread engine in Rust | ⛔ by D47 |
| D47 | **Read-state reconciliation layer in Swift** (`HaloDomain.ReadState`): a pure policy over SDK and server signals; it never recounts events itself in the MVP. Upgrade to an independent recount only if gate G-UNREAD fails | ✅ ADR-0007 |
| D9 | The badge is never incremented; it is always recomputed by one function used by both the app and the NSE | ✅ |
| D66 | **Gate G-NSE at the end of M1**, independent of G-FFI: the NSE must meet AC-NSE-1…6 (memory, execution time, timeout handling, extension termination, network failures, fallback behaviour). Founder decision 2026-11-19 | ✅ ADR-0016 |
| D65 | **Push notifications are synchronisation hints, never the source of truth.** The local unread engine (`ReadStatePolicy` / `BadgeCalculator`), fed by Matrix sync state through the SDK, is the sole authority for unread counts and the app badge. No push may set `aps.badge`; no payload field is read as a count or a read position; a push only triggers work (NSE fetch through the SDK, or an app reconcile). Founder decision 2026-11-19 | ✅ ADR-0015 |
| D10 | Self-hosted Sygnal, `event_id_only`; request the notification-filtering entitlement | ✅ ADR-0010 |
| D11 | Read-elsewhere clearing: best effort via background pushes + full reconcile on foreground | ✅ |
| D17 | Until threads ship: thread events inline, unthreaded receipts | ✅ |

## MVP scope
| ID | Decision | Status |
|---|---|---|
| D14 | MVP = auth, E2EE, room list, timeline, text, push, unread, replies, edits, deletes, reactions, stickers v1 | ✅ (confirmed by D45) |
| D16 | Media: display all incoming; send images | ✅ |
| D29 | MVP bot support = generic HTML-subset rendering + view source only | ✅ |

## Stickers
| ID | Decision | Status |
|---|---|---|
| D12 | `m.sticker` + MSC2545 (`im.ponies.*`) packs, personal packs in account data | ⛔ by D48 |
| D48 | **Stickers use the stable spec image packs (Matrix v1.19)**: `m.room.image_pack` room state + `m.image_pack.rooms` account data; personal packs are a private room owned by the user; send `m.sticker`. Read legacy `im.ponies.*` packs (read-only) for compatibility | ✅ ADR-0011 |
| D13 | Animated: WebP/GIF/APNG only | ✅ |

## Bots
| ID | Decision | Status |
|---|---|---|
| D18 | Bot account and backend are never changed; the app talks to the bot only via Matrix messages; no LLM in the app; the bot backend is the source of truth for bot business data | ✅ ADR-0012 |
| D19 | `BotMessageRenderer` is a Swift UI-layer module, independent of the Matrix adapter | ✅ |
| D20 | Two layers: generic rendering + strict, versioned template parsers for allowlisted bots | ✅ |
| D21 | No tables/charts until a separately approved, backward-compatible bot change | ✅ |
| D22 | Checkbox → the existing 👍 reaction on the original confirmation event; pending until the bot confirms | ✅ |
| D23 | List rows map via (room, bot sender, entity id parsed from the bot's own "Added Task #N" event); otherwise read-only | ✅ |
| D26 | Bot Activity tab after the MVP (P2) | ✅ |

## P1/P2 data features
| ID | Decision | Status |
|---|---|---|
| D30 | Search: local index; **evaluate the upstream `SearchService` first** | ✅ |
| D31 | Bookmarks: private "Saved" room | ✅ |
| D32 | Backup: on-demand encrypted export | ✅ |
| D33 | Saved message = copy + origin header + permalink + origin ids | ✅ |
| D34 | Global media gallery from a local media index (entry point revised by D83) | ✅ |

## Quality, licensing, process
| ID | Decision | Status |
|---|---|---|
| D28 | Order after core messaging: unread hardening → stickers → bot template cards | ✅ |
| D35 | Unread tests: pure policy + property tests, Synapse scenarios, on-device auditor, replay | ✅ ADR-0009 |
| D36 | CI: Linux for docs, domain logic and Synapse scenarios; Apple builds on a local Mac | ✅ ADR-0009 |
| D37 | Clean-room, behaviour-only reference for Element X | ✅ ADR-0013 |
| D38 | Professional legal review before any public release | ✅ |
| D39 | Automated licence gate; generated acknowledgements screen | ✅ |

## Engineering defaults (recorded in the Phase 0 review)
These were stated as decisions inside individual documents without an ID; they are recorded here so every `[DECISION]` label resolves.

| ID | Decision | Status |
|---|---|---|
| D49 | Swift 6 language mode with complete strict concurrency checking in every package; zero warnings ([architecture/CONCURRENCY.md](architecture/CONCURRENCY.md) §1) | ✅ |
| D50 | Navigation: `TabView` with Chats, Stickers, Settings; Activity added in P2; one typed `NavigationStack` per tab ([design/NAVIGATION.md](design/NAVIGATION.md)) | ⛔ by D85 |
| D51 | Sticker favourites/recents in account data `one.mbm.halo.sticker_prefs` and Halo-created pack rooms in `one.mbm.halo.sticker_rooms`; accepted that this account data is readable by the server operator ([features/STICKERS.md](features/STICKERS.md) §3, [security/PRIVACY.md](security/PRIVACY.md) §2) | ✅ |
| D52 | Personal-pack images are produced at exactly 512 px on the long side, as animated/static WebP or PNG (STICKERS FR-7) | ✅ |
| D53 | The NSE never runs a `halo.sqlite` migration that takes longer than 1 s; it opens read-only and degrades ([data/MIGRATIONS.md](data/MIGRATIONS.md) §1) | ✅ |
| D54 | Halo-specific account data uses the `one.mbm.halo.*` namespace (root per D63), versioned JSON with unknown fields preserved ([data/DATA_MODELS.md](data/DATA_MODELS.md) §4) | ✅ |
| D55 | SDK media cache retention defaults to 1 GB / 30 days ([data/PERSISTENCE.md](data/PERSISTENCE.md) §5; V-MEDIA-1) | ✅ |
| D56 | Image upload strips location EXIF and converts HEIC → JPEG; max dimension 4096 px, quality 0.85 ([matrix/MEDIA.md](matrix/MEDIA.md) §2) | ✅ |
| D57 | URL previews are off by default in E2EE rooms ([matrix/MEDIA.md](matrix/MEDIA.md) §3) | ✅ |
| D58 | Logging through `os.Logger` behind the `HaloLog` facade, subsystem `N` (D63) ([architecture/LOGGING_AND_DIAGNOSTICS.md](architecture/LOGGING_AND_DIAGNOSTICS.md) §1) | ✅ |
| D59 | No third-party crash SDK in the personal phase: Xcode Organizer/TestFlight reports + MetricKit (revisit: Q-CRASH) | ✅ |
| D60 | Rooms created by Halo (DMs, private rooms) are encrypted by default ([security/SECURITY.md](security/SECURITY.md) §2) | ✅ |
| D61 | App-switcher privacy blur when backgrounding, default on ([security/SECURITY.md](security/SECURITY.md) §4) | ✅ |
| D63 | **One project-owned namespace root `N`** = **`one.mbm.halo`** (reverse-DNS of a domain the founder controls) for every identifier of the app, the NSE and future extensions: bundle IDs, App Group, Keychain access group, BG task ids, log subsystem, Darwin notifications, Sygnal app id and Halo account-data types. Derivation table: [development/DEVELOPMENT_SETUP.md](development/DEVELOPMENT_SETUP.md) §3. (resolves Q-BUNDLE; founder decisions 2026-11-19) | ✅ |
| D64 | **M0 uses Synapse's native Matrix username/password login**; `infra/dev` runs without MAS until M5, when OIDC/MAS integration is added (resolves Q-DEV-AUTH; founder decision 2026-11-19) | ✅ |
| D67 | **Session Handoff Rule:** before every `git push`, `HANDOFF.md` (status, completed work, key decisions, modified files, outstanding issues, next steps, Next Session Prompt) and all affected specs/roadmap statuses are updated, and the last commit of the push includes the handoff. Enforced by a pre-push hook, a CI check and the docs validator (AGENTS.md §18). Founder decision 2026-11-19 | ✅ |
| D62 | swift-format default style at 120 columns; SwiftLint only for custom rules ([development/CODE_CONVENTIONS.md](development/CODE_CONVENTIONS.md) §1) | ✅ |
| D68 | Sticker panel reads a room's whole state only for rooms with ≤ 1,000 joined members, else just the empty-key pack; room packs cached in memory for 10 min ([features/STICKERS.md](features/STICKERS.md) §9). Code review of PR 5, 2026-11-20 | ✅ |
| D69 | Per-account state kept in memory (read intents, drafts, sticker prefs) is dropped when the account signs out or changes; pending receipts and sticker recents are sent before sign-out. Code review of PR 5, 2026-11-20 | ✅ |
| D70 | **Autonomous loop with self-merge:** an AI agent works the ROADMAP queue in Plan → Implement → Verify iterations without asking to continue, and merges its own pull request (merge commit) once all CI checks pass, local checks (prepush, app build, touched contract tests) pass, and its review leaves no high/medium finding; gate outcomes, dependencies, licences, security settings and ADR changes still wait for the founder ([development/AUTONOMOUS_LOOP.md](development/AUTONOMOUS_LOOP.md)). Founder decision 2026-11-20 | ✅ |
| D71 | **Q-CI-MAC deferred (founder, 2026-11-20):** no macOS CI job for now; `scripts/prepush.sh` is the only Mac validation gate. Revisit when the core build pipeline is stable and a CI runner is confirmed to support the required Xcode. Not blocking. Founder decision 2026-11-20 | ✅ |
| D72 | `read_intent` confirmation rules (a) and (b) of READ_RECEIPTS §1 are not implemented: sent intents are kept until the 7-day expiry, because deleting them early drops the local read position that quiet-unread rooms need (S07b) and the room list has no own-receipt event ID. Rule (c) holds. Failed sends are recorded in `attempts`/`last_error` and logged (category `readstate`, no content). Agent decision under D70; revisit if storage growth shows up in the auditor. | ✅ |
| D73 | **V-RS-7 closed (founder, 2026-11-20):** classic Matrix sync is the authoritative source of unread evidence on the production path; push records are supplementary (background notifications), never the sole source. Server zero never marks a room read by itself; encrypted and unencrypted rooms follow their own reconciliation rules; an incomplete or empty evaluation never overwrites the stored attention set the notification extension uses (`BadgeCoordinator` carries over rooms the list hasn't shown yet); the badge derives from reconciled state. No upstream SDK or Synapse change unless implementation shows the interfaces insufficient. Correctness of unread state and badge persistence are **P0 acceptance criteria**. Verified: the pinned SDK exposes the per-room evidence over classic sync (`syncV2`, `ClassicSyncEvidenceTests`); classic sync does not solve the NSE's background-state problem. Founder decision 2026-11-20 | ✅ |
| D74 | **Classic sync in the adapter (implements D73):** the app no longer runs sliding sync (`slidingSyncVersionBuilder(.none)`). `MatrixSessionPort` runs its own `Client.syncOnceV2` loop (first call with timeout 0, then an 8 s long poll; a retryable error reports `.offline` and backs off 1→60 s, any other error ends the loop with `.failed` for `SyncCoordinator` to restart). The poll is short because cancelling the task does not interrupt the SDK call and `client.logout()` waits for it; `stopSync` waits at most 1 s and a later start waits for the old loop. `MatrixRoomListPort` rebuilds only the rooms a response names, orders by latest event (invites first) and publishes the list as a `.reset`; there is nothing to page (`loadMore` is a no-op). `MatrixTimelinePort.open` requests one page in the background because classic sync doesn't pre-fill a timeline the way sliding sync did. The room-list view model now also refreshes on read-input changes (the status alone doesn't change when counts do). Agent decision under D70/D73; the first-sync cost on large accounts is unmeasured. | ✅ |
| D75 | **Pull requests only for milestones and big features (founder, 2026-11-20):** small changes (fixes, tweaks, settings rows, docs, roadmap sub-items) are committed directly to `main` after `scripts/prepush.sh` passes, with HANDOFF.md in the last commit; no branch, no PR. Supersedes the one-PR-per-roadmap-item wording of D70; the self-merge conditions of AUTONOMOUS_LOOP §3 still apply to the PRs that are opened. | AUTONOMOUS_LOOP §3, AGENTS §16 |
| D76 | **Sessions list over one direct HTTP call (founder, 2026-11-21):** `GET /_matrix/client/v3/devices` in `MatrixDevicesPort` (read-only, token never logged, IPs ignored) because the SDK has no device list; signing out other sessions (needs UIA) is not built. See ADR-0018. | Accepted |
| D77 | **Change password over one direct HTTP call (founder request, 2026-11-21):** `POST /account/password` with password UIA in `MatrixAccountPasswordPort` (other sessions stay signed in, passwords never logged or stored, not offered to accounts signed in through an identity service). See ADR-0019. | Accepted |
| D78 | **E3c: a server count the SDK doesn't share is no unread (founder approved the R-01 fix, 2026-11-21):** in an encrypted room the policy uses the SDK's counts whenever any is non-zero (E3b; a call invite is a notification without being a message), and server counts with all SDK counts at zero give no unread and no attention (`ENC_SERVER_ONLY`, explained). Reason: the server counts every encrypted event (poll votes, encrypted reactions) while the SDK, which over classic sync (D74) holds the same events and counts undecryptable ones, decides from the decrypted content (F-SDK-3). Replaces the former E3c "SDK blind → dot", written for sliding sync, where rooms outside the window had no events. Trade-off: a message the SDK never received (a gap whose newest events are all non-messages) shows only through a push record (E4). See docs/CODEBASE_REVIEW.md R-01. | ✅ |
| D79 | **E1/E1b give way to the SDK's counts once the SDK has applied the read position (founder approved the R-07 fix, 2026-11-21):** the policy gets the receipt the SDK holds (`RoomReadInputs.receiptReadThrough`) apart from the merged read position. When the read position covers the latest event and that receipt is at least the read position, or the own latest event is on the server (not a local echo), any positive SDK count means unread after it (`SDK_UNREAD_AFTER_READ`), and evaluation continues with E2/E3. Reason: the SDK's latest event leaves out events it can't decrypt, so "covers the latest event" hid them (F-SDK-3, confirmed live). Kept: a local read position ahead of the SDK's receipt (not sent or not echoed yet) still clears at once (E1), and so does a pending local echo (E1b). Side effect: a clock-skewed message after a confirmed read now shows (S18). See docs/CODEBASE_REVIEW.md R-07. | ✅ |
| D80 | **Order read state by event identity and timeline order, not timestamps (revises D47 and D72, R-06, 2026-11-21):** open timelines pick receipt candidates by timeline index (`TimelineReadTracker`) and target `Timeline.latestEventId()` at the tail (clearing trailing non-row events such as poll votes, R-01 leftover); `read_intent` adds monotonic `timeline_order` (migration v8) so equal-ms and clock-skewed later events advance cleanly; E1 compares event IDs when both are known and yields (`INTENT_STALE`) once a sent receipt is confirmed by the server/sync yet counts remain non-zero. See ADR-0020. | ✅ ADR-0020 |
| D81 | **Remove native sliding-sync gate at login (R-17, 2026-11-21):** since Halo uses classic `/sync` (`slidingSyncVersionBuilder(.none)`, D74), server discovery and password login no longer require `supportsNativeSlidingSync` (amends AUTHENTICATION FR-5). | ✅ |
| D82 | **App icon badge = total unread message count across rooms needing attention (founder decision, supersedes D5, 2026-11-21):** `BadgeCalculator.badge(_ states)` sums `RoomReadState.badgeCount` for rooms with `attention == true` (`allMessages`: `max(notify, highlight, 1)`, `mentionsAndKeywords`: `max(highlight, 1)`, muted marked-unread / invite: `1`). `AttentionCache` stores per-room counts + timestamp so the NSE recomputes from GRDB `notification_record` without raw increments (D9, D65 preserved). See ADR-0021. | ✅ ADR-0021 |
| D83 | **Global media gallery as a preset virtual room entry in the room list, not a tab (founder decision, refines D34 & D50, 2026-11-22):** do not use a tab to organize or display photos/media. Instead, present the global media gallery as a preset room entry in the room list. This preset entry is purely a local UI entry—**not** a Matrix room (no server room ID, no Matrix sync state, excluded from unread counts, read receipts, and the app badge). Tapping it opens the global media gallery view to display and organize media across rooms ([design/NAVIGATION.md](design/NAVIGATION.md), [features/ROOM_LIST.md](features/ROOM_LIST.md)). | ✅ |
| D84 | **Apple-native look and feel is the UX north star (founder direction, 2026-11-22):** Halo should feel like a first-party Apple app — system components, iOS 26 materials, Apple interaction patterns, Dynamic Type and SF Symbols — while keeping its own colours, icon and artwork (D37). Custom controls need a written reason. Drives ROADMAP M11–M15 and the ship-ready definition ([design/UX_AUDIT.md](design/UX_AUDIT.md), [design/DESIGN_SYSTEM.md](design/DESIGN_SYSTEM.md) §1) | ✅ |
| D85 | **One `NavigationStack`, no tab bar (founder decision, 2026-11-22, supersedes D50, resolves Q-NAV-SHELL):** Messages-style shell — room list as the only root with a large "Chats" title; account avatar top-leading → Settings (pushed); compose top-trailing → New chat (sheet); a more menu with filters, Stickers and Activity (pushed); `.searchable` room list with a "Messages" results section; one typed router for all deep links; no tab badge ([design/NAVIGATION.md](design/NAVIGATION.md) §1) | ✅ |
| D86 | **Module and folder layout v2 (founder, 2026-11-22, ADR-0022, refines ADR-0008):** files move to their owning layer (`TimelineReadTracker` → `HaloDomain`, preferences port, routes → `HaloApplication`), new `FeatureSearch`/`FeatureProfile`/`FeatureMedia`/`FeatureComposer`/`HaloBotRendering`, `FeatureAuth` → `FeatureOnboarding`, `App/{Composition,Resources,Support}`, then two manifests (`HaloCore` Linux, `HaloApple`) with matching area folders; naming stays `Halo<Layer>` / `Feature<Area>` ([architecture/MODULE_BOUNDARIES.md](architecture/MODULE_BOUNDARIES.md) §1). Four steps queued in ROADMAP M11–M13 | ✅ |
| D87 | **Share extension stages, the app sends (founder picked it first from M16, 2026-11-22):** the `HaloShareExtension` target (`com.apple.share-services`) accepts text, one web URL, ≤ 10 photos and ≤ 10 files, writes them to a `share-inbox/` folder of the App Group (`FileShareInbox`, ≤ 50 MiB, expires after 7 days) and ends; it has no session, never talks to the homeserver and never starts sync (AGENTS §17). The app lists the inbox when it becomes active and shows "Send to…" (`ShareTargetPickerView`); `ShareCoordinator` sends item by item through the timeline's normal path, so a send looks unconfirmed until the server accepts it (§4.4). A payload is deleted only after every item is sent. Why not send from the extension: it would need the Keychain session and a second SDK instance in a ~120 MB process (R-25 class risk). Deferred: choosing the chat inside the extension, Share → direct to a favourite | ✅ |
| D88 | **Open a chat from Siri, Shortcuts and Spotlight, opt-in (M16, 2026-11-22):** Settings → Privacy → "Chats in Siri and Spotlight" (`PreferencesSnapshot.chatsInSystemSearch`, default **off**). While on, `ChatShortcutPublisher` stores the names and IDs (never messages, previews or avatars) of up to 100 joined chats (favourites first) in an App Group file for the `OpenChatIntent` App Intent and in a Spotlight index (`SystemChatShortcutStore`); off or signed out removes both. The intent only sets `OpenChatRequest`; the root view opens the room through `ChatsRouter` (no second navigation path). Why opt-in: chat names leave the app's sandbox into system search. Deferred: sending a message by Siri, Focus filter | ✅ |
| D89 | **Unread widget shows the app's last evaluated count and nothing else (M16, 2026-11-22):** `HaloWidgetExtension` (home-screen small, lock-screen circular, rectangular and inline) reads `AttentionCache` from the App Group and adds the stored per-room counts like the icon badge (D82); it never evaluates read state (AGENTS §4.2), reads no room names or messages, marks counts older than 6 h "may be out of date" (§4.4) and marks the number `privacySensitive`. `SystemBadge` reloads the timelines when it writes or resets the counts. Deferred: a chat-list widget (needs names, so an opt-in like D88), interactive widgets | ✅ |
| D90 | **Focus filter narrows the chat list only (M16, 2026-11-22):** Settings → Focus → Halo offers "Show only People / Rooms / Favourites / Unread" (`HaloFocusFilter`, `SetFocusFilterIntent`). While the Focus is on, `RoomListViewModel.effectiveFilter` uses it instead of the person's own filter (kept untouched); a banner offers "Show all chats" until the Focus changes. The app reads `HaloFocusFilter.current` whenever it becomes active, so a missed change corrects itself. It does not silence notifications or change the badge (the Focus's own allow-list does that; AGENTS §4.2). Deferred: per-Focus notification levels | ✅ |
| D91 | **iPad: the same shell as a split view (M16, 2026-11-22, refines D85):** the app targets iPhone and iPad (`TARGETED_DEVICE_FAMILY = 1,2`, all iPad orientations). On iPad the chat list is the sidebar of a `NavigationSplitView` and the router's path is the detail column ("Select a chat" when empty); narrow windows collapse to one column. `ChatsRouter.replacesDetail` makes a room or top-level destination opened from the sidebar replace the detail (threads and Settings → Stickers still stack). iPhone behaviour is unchanged (one `NavigationStack`, D85). Sign-in content is capped at 520 pt. Deferred: three-column layout, keyboard shortcuts, drag and drop, Stage Manager testing on a device | ✅ |
| D92 | **The share extension sends from the share sheet (founder, 2026-11-22, ADR-0023, refines D87):** after staging, the extension restores the SDK session like the NSE, lists joined chats from the local store, sends to the chosen chat and waits up to 90 s for the server (`SendConfirmation`); unconfirmed sends stay queued in the shared store for Halo to finish. No session or unreadable store falls back to the staged items plus a local notification. Still no `SyncService` in the extension (AGENTS §17) | ✅ ADR-0023 |
| D93 | **Unread chats widget reuses the opt-in chat list (M16, 2026-11-22, builds on D88/D89):** the medium widget lists up to four chats with unread counts (`UnreadChatsSnapshot`): counts from `AttentionCache` (D82), names from the chat-shortcuts file that exists only while "Chats in Siri and Spotlight" is on. With it off the widget shows no chats and says how to turn it on; it never shows room IDs or message text. Names and counts are `privacySensitive` (hidden on a locked screen). No new setting, no new data file | ✅ |
| D94 | **Calls will not be implemented (founder, 2026-11-22, supersedes D43's "keep the path open"):** Halo is a messaging client; voice and video calls, MatrixRTC and the Element Call widget are out of scope for 1.0 and the post-1.0 backlog. Call events keep rendering as timeline items (D43's MVP behaviour). Reopen only by a new decision | ✅ |
