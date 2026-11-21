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
| D43 | Calls: keep the MatrixRTC / Element Call widget path open; MVP only renders call events | ✅ |

## Unread, receipts, notifications (P0)
| ID | Decision | Status |
|---|---|---|
| D5 | App icon badge = number of rooms needing attention | ✅ |
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
| D34 | Global media gallery from a local media index | ✅ |

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
| D50 | Navigation: `TabView` with Chats, Stickers, Settings; Activity added in P2; one typed `NavigationStack` per tab ([design/NAVIGATION.md](design/NAVIGATION.md)) | ✅ |
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
