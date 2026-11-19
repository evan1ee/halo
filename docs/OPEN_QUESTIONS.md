# Open Questions and Validation Items

- **V-*** = an assumption that needs technical validation (with the exact check). **Q-*** = an open decision (with options).
- "Blocks" = the earliest milestone that can't finish without the answer.

## Validation items

| ID | Assumption | Exact validation | When | Blocks |
|---|---|---|---|---|
| V-SDK-1 | ~~Each prebuilt release maps to an identifiable SDK commit and feature set~~ **Resolved** — the release commit names it: `26.11.17` ← SDK `b93751e`, features `sentry`, profile `small-release-stripped` (`ios/SDKVERSION.md`); facts and inventory re-checked there [VERIFIED SOURCES pinned refs, F-LIC-2] | — | — | — |
| V-SQL-1 | ~~SDK SQLite and GRDB coexist in one process~~ **Resolved (2026-11-19)**: the SDK's `sqlite3_*` symbols are local to its static library, and a test (`SQLiteCoexistenceTests`) runs a syncing SDK client with its SQLite store next to Halo's GRDB database in one iOS-simulator process without interference [VERIFIED, local run on SDK 26.11.17 + GRDB 7.12.0] | — | — | — |
| V-SQL-2 | GRDB `DatabasePool` shared by app + NSE works without `0xdead10cc` terminations when following GRDB's suspension guidance | NSE spike: 100 pushes while the app is backgrounded and writing | M1 | M3 |
| V-CI-1 | ~~GRDB builds and tests on Linux with system SQLite~~ **Resolved** — yes, with `libsqlite3-dev` in the `swift` image [VERIFIED F-CI-1] | — | — | — |
| V-CI-2 | ~~Linux CI Swift minor equals Xcode's~~ **Resolved (2026-11-19)** — they differ: Xcode 27.2 ships Swift 6.4.2, CI uses 6.2.4. Packages are `swift-tools-version: 6.2` and pass on both; CI stays on 6.2 as the floor [VERIFIED local run] | — | — | — |
| V-NSE-1 | NSE memory/time budget suffices for the SDK client + one decryption | Instruments on the oldest supported device; record peak memory and duration over 50 pushes | M1 | M1 (G-NSE) |
| V-NSE-2 | Reading RoomInfo for all rooms in the NSE for the badge fits the budget | Measure with 300 rooms; else use cached badge ± current room | M1 | M1 (G-NSE) |
| V-NSE-3 | `use_lightweight_tokio_runtime = true` lowers NSE memory | A/B measurement in the spike | M1 | — (G-NSE input) |
| V-PUSH-1 | Sygnal maps the pusher `default_payload` into the APNs payload as expected (`mutable-content`, generic alert) | Read Sygnal docs; send a test push; inspect the device payload | M1 | M1 |
| V-PUSH-2 | ~~Count-change pushes arrive as background pushes with our pusher config~~ **Resolved — false with stock Sygnal**: they arrive as `aps.badge`-only pushes [VERIFIED F-PUSH-1, F-PUSH-2]; replaced by V-PUSH-5 and ADR-0015 | — | — | — |
| V-PUSH-3 | Apple grants `com.apple.developer.usernotifications.filtering` | Submit the request in M1 | M1 → M3 | — (fallback exists) |
| V-PUSH-5 | A Sygnal pushkin subclass (ADR-0015 option 1) can send count-only notifications as background pushes (`content-available`, no `badge`, push type `background`, priority 5) while event pushes stay alert pushes, and iOS wakes the app for them | Implement in `infra/dev`; read on another device; check the device payload and app wake-ups (Console); confirm the icon badge is unchanged | M1 | M1 (else the relay fallback, ADR-0015 condition 4) |
| V-PUSH-4 | The notification Reply action launches the app in the background long enough to send | Device test | M3 | — |
| V-RS-1 | `subscribe_to_room_info_updates` fires when own receipts / counts change, and whether room-list entries carry the same `RoomInfo` (decides the single per-room source, PORTS_CONTRACT §3) | Adapter test against the dev Synapse with a second client reading; compare both sources for 50 rooms | M1 | M3 |
| V-RS-3 | The adapter can supply a timeline order index for events in open timelines (clock-skew mitigation) | Inspect timeline item APIs at M2 | M2 | — |
| V-RS-6 | Synapse counts every encrypted event as notifying in all-messages mode, and gives 0 in mentions/keywords or mute mode for encrypted rooms (basis of `serverCanCount`) | Scenarios S06, S07, S21 inspecting `/sync` counts on the pinned Synapse | M3 | M3 |
| V-RS-4 | Receipts on the latest *visible* event (skipping hidden state events) clear server counts | Scenario with hidden state events after the last message | M3 | M3 |
| V-RS-5 | Which sliding-sync extensions `RoomListService` enables for which rooms (receipts coverage) | Log the SSS request bodies from the SDK on the dev Synapse | M1 | M3 |
| V-SYNC-2 | The SDK send queue persists unsent events across app restarts | Kill during send offline; relaunch; observe | M2 | M2 |
| V-TL-1 | ~~An event-focused timeline is available via `timeline_with_configuration`~~ **Resolved** — `TimelineFocus.Event` exists [VERIFIED F-FFI-22] | — | — | — |
| V-RL-1 | Room tags beyond favourite are reachable | `set_is_favourite` exists **[VERIFIED F-FFI-18]**; other tags unknown → not needed in the MVP | M2 | — |
| V-E2EE-1 | Encryption API names for recovery and backup | Inspect `encryption.rs` at M1 | M1 | M1 |
| V-MEDIA-1 | Media retention policy can be configured as planned | Inspect `set_media_retention_policy` parameters | M2 | — |
| V-FFI-1 | Cancellation semantics of UniFFI async calls | UniFFI manual + a test | before any Halo-owned FFI | G-FFI fail path |
| V-FFI-2 | Panics map to an error for the caller | UniFFI manual | same | same |
| V-ST-1 | `Room.state_events("m.room.image_pack")` returns pack state for joined rooms | M4 week-1 test; else option B (authenticated GET in the adapter) | M4 | M4 |
| V-ST-2 | The adapter can obtain a valid access token / trigger a refresh for option B | Inspect `Client.session()` and the session delegate | M4 | M4 (if B) |
| V-ST-3 | Legacy pack event names `im.ponies.user_emotes`, `im.ponies.room_emotes`, `im.ponies.emote_rooms` | MSC2545 history + FluffyChat/Cinny source (licence-safe: read docs/specs, not copy) | M4 | — |
| V-SEARCH-1 | Upstream `SearchService` fits Halo's search needs (E2EE rooms, ranking, index size) | Spike in M8 | M8 | M8 |
| V-APPLE-1 | ~~Apple platform facts used in the design~~ **Resolved for Observation, the filtering entitlement, file protection, NSE entry point and BGTaskScheduler [VERIFIED F-APPLE-1]**; NSE time/memory limits are measured at G-NSE and ImageIO animation formats in M4 | — | — | M4 (ImageIO) |
| V-AUTH-1 | When MAS is introduced in M5, how existing `infra/dev` users and password-login sessions carry over (MAS migration tooling vs a fresh dev server) | Read the MAS docs for the version pinned at M5; try on a copy of the dev database | M5 | M5 |
| V-LEGAL | Export compliance and trademark checks | Lawyer / Apple guidance | before external TestFlight | external TestFlight |

## Open decisions

| ID | Question | Options | Recommendation | Decide by |
|---|---|---|---|---|
| Q-BUNDLE | Bundle ID prefix, App Group, account-data namespace | — | **Decided D63**: namespace root `one.mbm.halo` for app and extensions (identifiers in DEVELOPMENT_SETUP §3) | — |
| Q-PUSH-BADGE | How to stop Synapse's count-only pushes from setting the icon badge | — | **Decided: ADR-0015 accepted with conditions, D65** — Halo pushkin; relay only as fallback | — |
| Q-XCODEGEN | ADR-0008 rejected a project generator, but adding packages to `ios/Halo.xcodeproj` by hand is error-prone: it was regenerated twice with XcodeGen from a spec kept outside the repo | Founder: adopt XcodeGen with a committed `project.yml` (new ADR), or hand-edit the project | Open — raise before the next package is added to the app | M0 |
| Q-DEV-AUTH | How M0's password login works when `infra/dev` includes MAS | — | **Decided D64**: native Synapse password login in M0; MAS from M5 | — |
| Q-NSE-GATE | NSE budget as its own gate? | — | **Decided: ADR-0016 accepted, D66** — G-NSE at the end of M1 with AC-NSE-1…6 | — |
| Q-SDK-BUILD | When to switch from the prebuilt SDK to building from source | M0 / before external TestFlight / never | Before the first external TestFlight | M5 |
| Q-MAS-ACCOUNT | Device/session management for OIDC accounts: native list or MAS account page | Native via SDK / web (`account_url`) | Web page in the MVP | M5 |
| Q-E2EE-STRATEGY | Room key recipient strategy (share keys with unverified devices?) | SDK default / identity-based / error-on-unverified | SDK default in the MVP; revisit with verification UX | M2 |
| Q-CRASH | Crash reporting before public release | Apple only / self-hosted Sentry-compatible / none | Apple + MetricKit; revisit | M10 |
| Q-CI-MAC | Use macOS CI runners for release candidates | Never / manual dispatch / always | Manual dispatch only | M5 |
| Q-BOT-OWNER | Allow ticking tasks owned by others (the bot ignores them) | Enable only for own tasks (needs reliable ownership) / enable all + timeout message | Enable all + clear timeout message in M6; refine when ownership is detectable | M6 |
| Q-ACT-REFRESH | Offer a visible "refresh from bot" command in the Activity tab | Yes (visible message) / no | No in M7; reconsider after use | M7 |
