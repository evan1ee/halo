# Roadmap

Capacity: solo, part-time (D24). Estimates are calendar weeks at ~15 h/week and are **[ASSUMPTION]**s,
to be re-planned after M0. Each milestone ends with its exit criteria **verified by tests** (see AGENTS.md §0 and §12).

## Implementation entry criteria (before M0 starts)

- [x] Phase 0 documentation approved by the founder (2026-11-19).
- [x] Apple Developer Program membership active; namespace root `one.mbm.halo` recorded (D63, DEVELOPMENT_SETUP §3).
- [x] Domain for the homeserver available; DNS control.
- [x] Mac with Xcode supporting iOS 26 SDK — available from 2026-11-19 (Xcode 27.2, iOS 26+ simulators); M0 proceeds with its Linux part, see below; Rust toolchain installable (only needed on the G-FFI or G-NSE fail paths, or for Q-SDK-BUILD).
- [ ] Open questions marked "blocks M0" in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) resolved (the remaining ones are M0 validation items, done during M0).

## M0 without a Mac (2026-11-19)
M0 started before the Mac is available. Work that runs on Linux is done first; the rest waits for the Mac and is the only thing
standing between M0 and its exit criterion.

| Part | Items | Needs |
|---|---|---|
| **M0a — Linux** | `infra/dev` (Synapse + Postgres, native password login, D64); Linux-buildable packages (`HaloFoundation`, `HaloDomain`, `HaloApplication`, `HaloTestSupport`) with the M0 ports `SessionPort` and `RoomListPort`, the session/room-count use case, fakes and contract tests; CI (`docs`, `swift-linux`, `boundaries`, `secrets`, `licenses`); V-CI-1; V-SDK-1 | This container / Linux CI |
| **M0b — Mac** | Xcode project (app + NSE targets, identifiers per DEVELOPMENT_SETUP §3); `HaloMatrixAdapter` implementing `SessionPort` + `RoomListPort` over the pinned `MatrixRustSDK`; `HaloPlatform` log sink; V-SQL-1; V-APPLE-1; V-CI-2; the exit criterion (password login against `infra/dev` shows the room count via ports) | Mac with Xcode for the iOS 26 SDK |

**Status (2026-11-19): M0a done.** `infra/dev` passes `smoke.sh`; the four Linux packages pass their tests on Swift 6.2.4;
`check-boundaries`, the licence gate (at SDK `b93751e`) and gitleaks pass locally; V-CI-1 and V-SDK-1 are resolved. The CI workflows
run once a pull request is open. **Remaining for M0 (all M0b, needs the Mac):** Xcode project, `HaloMatrixAdapter` for `SessionPort` +
`RoomListPort` passing `SessionPortContract` / `RoomListPortContract` against `infra/dev`, `HaloPlatform` Keychain and log sink,
V-SQL-1, V-APPLE-1, and the exit criterion.

**M1 started (2026-11-19):** read-only timeline slice — `TimelinePort` (domain, fake, contract, adapter), `TimelineCoordinator`, `FeatureTimeline`, tap a room to read it (text, notice, emote, media placeholders, deleted, undecryptable, membership, date dividers) — verified on the simulator against `infra/dev`. Also done: `SyncPort`/`SyncCoordinator`, `HaloPersistence` (V-SQL-1 resolved), `MediaPort`/`MediaLoader` with inline image thumbnails. Also done: recovery-key verification (`EncryptionPort`, banner + sheet). Remaining for M1: QR/emoji verification, UTD reasons, NSE spike and G-NSE (needs a physical device), video/audio/file display.

**M0 exit criterion met on the simulator (2026-11-19):** the app signs in with a password against `infra/dev` and shows the room count and names; a relaunch restores the session without signing in (AC-AUTH-1/2 manually). Not yet: signed device build, shared Keychain access group, NSE pipeline (M1), V-SQL-1, V-APPLE-1. Earlier M0b notes:

**M0b started (2026-11-19):** V-CI-2 resolved; `ios/Packages/HaloMatrixAdapter` exists and builds against the pinned SDK 26.11.17 for the iOS Simulator. The prebuilt xcframework has no macOS slice, so the adapter builds and tests only through `xcodebuild` with an iOS destination (not `swift build`/`swift test`).

## Milestones

```mermaid
gantt
  dateFormat  YYYY-MM-DD
  axisFormat  %b
  section MVP
  M0 Foundation          :m0, 2026-12-01, 4w
  M1 Read-only client    :m1, after m0, 7w
  M2 Messaging           :m2, after m1, 7w
  M3 Read-state engine   :m3, after m2, 7w
  M4 Stickers v1         :m4, after m3, 5w
  M5 MVP hardening       :m5, after m4, 5w
  section P2
  M6 Bot cards           :m6, after m5, 4w
  M7 Bot Activity        :m7, after m6, 4w
  M8 Search + Saved      :m8, after m7, 6w
  M9 Gallery + Export    :m9, after m8, 5w
  M10 Threads            :m10, after m9, 6w
```

| # | Milestone | Scope | Exit criteria | Gates |
|---|---|---|---|---|
| M0 | Foundation | Repo layout, Xcode project + local packages, `infra/dev` Synapse (native password login, D64)/Sygnal, prebuilt SDK pinned, adapter skeleton behind ports, licence gate, CI (docs + Linux Swift domain tests), logging | Password login against the dev Synapse shows the room count via ports; CI green | V-SDK-1, V-SQL-1, V-CI-1, V-APPLE-1 |
| M1 | Read-only client | Session restore, `SyncService`, room list, timeline (text, notices, images, UTD), verification + recovery, NSE spike | All rooms readable; encrypted push shown | **G-NSE** (AC-NSE-1…6) |
| M2 | Messaging | Composer, replies, edits, deletes, reactions, typing, receipts display, send queue, media display, image send | Daily use alongside Element X; AC-M* | — |
| M3 | Read-state engine | `ReadState` policy, receipt outbox, visibility tracking, badge, clearing, marked-unread, modes, auditor, Synapse scenario suite | AC-U1–U7 automated green | **G-UNREAD, G-FFI** |
| M4 | Stickers v1 | Image-pack discovery, panel, favourites/recents, search, send/render, personal pack creation | AC-S* | V-ST-1 |
| M5 | MVP hardening | OIDC/MAS login (MAS added to `infra/dev`, V-AUTH-1), settings, acknowledgements, generic bot rendering, performance, 7-day soak | **MVP: daily-driver switch**, AC-U8 | — |
| M6 | Bot cards | Template parsers v1, task→event index, reaction protocol | AC-B* | — |
| M7 | Bot Activity tab | Task aggregation, filters, jump to source | AC-A* | — |
| M8 | Search + Saved | Evaluate `SearchService` → decide; Saved room | Known message found in an E2EE room | V-SEARCH-1 |
| M9 | Gallery + Export | Media index, gallery, encrypted export | — | — |
| M10 | Threads | Thread UI + per-thread read state | Unread scenarios with threads green | — |

## Gates

| Gate | When | Question | Pass → | Fail → |
|---|---|---|---|---|
| **G-FFI** | End of M3 | Are the upstream FFI APIs enough for unread correctness, stickers (custom room state)? (NSE budget: G-NSE.) | Stay on the upstream binary framework | Build Halo-owned UniFFI bindings over `matrix-sdk`/`matrix-sdk-ui` in `core/` behind the same ports (ADR-0003); budget 6–10 weeks |
| **G-NSE** (ADR-0016) | End of M1, independent of G-FFI | Does the NSE meet AC-NSE-1…6 — memory, execution time, timeout handling, extension termination, network failures and fallback behaviour ([features/NOTIFICATIONS.md](features/NOTIFICATIONS.md) §11)? | Keep the NSE pipeline | Lightweight runtime, cached badge, SDK built without unneeded features (Q-SDK-BUILD moves to M2); Halo-owned bindings only if the binding layer is the measured cost |
| **G-UNREAD** | End of M3 | Does the reconciliation policy over SDK + server signals meet AC-U1–U7 in scenario tests? | Keep the policy layer | Add an independent recount (needs G-FFI fail path, or upstream fixes) |

## Dependencies

```mermaid
flowchart LR
  M0 --> M1 --> M2 --> M3 --> M5
  M2 --> M4 --> M5
  M3 --> M10
  M5 --> M6 --> M7
  M5 --> M8 --> M9
  M1 -. media cache .-> M4
```

## Technical risks per milestone
See [RISK_REGISTER.md](RISK_REGISTER.md). Highest: T-NSE (M1), T-RECEIPTS (M3), T-STATE (M4), and the capacity risk PROJ-1 across all milestones.
