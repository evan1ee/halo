# Phase 0 — Documentation Completeness Report

Date: 2026-11-19 · Branch: `claude/blissful-galileo-3400g9` · Status: **approved by the founder (2026-11-19)**; reviewed (§9); founder decisions recorded (§10).

## 1. Files created

| Area | Files |
|---|---|
| Root | `AGENTS.md` (engineering contract), `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `LICENSE` (proprietary), `.gitignore`, `.github/workflows/docs.yml` |
| Product | `docs/README.md`, `PRODUCT_VISION.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `GLOSSARY.md` |
| Decisions and tracking | `DECISION_LOG.md` (D1–D66, superseded entries kept), `adr/` (README, TEMPLATE, ADR-0001…0016, all accepted), `OPEN_QUESTIONS.md`, `RISK_REGISTER.md`, `SOURCES.md`, this report |
| Architecture (9) | `OVERVIEW`, `SYSTEM_DESIGN`, `MODULE_BOUNDARIES`, `DATA_FLOW`, `CONCURRENCY`, `ERROR_HANDLING`, `BACKGROUND_EXECUTION`, `LOGGING_AND_DIAGNOSTICS`, `ARCHITECTURE_DECISIONS` |
| Matrix (8) | `SDK_INTEGRATION`, `RUST_FFI`, `PORTS_CONTRACT`, `SYNC_ENGINE`, `UNREAD_STATE`, `READ_RECEIPTS`, `PUSH_NOTIFICATIONS`, `MEDIA` |
| Feature specs (13 + template) | `AUTHENTICATION`, `ENCRYPTION_AND_DEVICES`, `ROOM_LIST`, `TIMELINE`, `MESSAGING`, `MEDIA_ATTACHMENTS`, `NOTIFICATIONS`, `ROOM_MANAGEMENT`, `USER_PROFILES`, `SETTINGS`, `STICKERS`, `BOT_MESSAGES`, `BOT_ACTIVITY` |
| Design (3) | `DESIGN_SYSTEM`, `NAVIGATION`, `SCREEN_SPECIFICATIONS` |
| Data (3) | `DATA_MODELS`, `PERSISTENCE`, `MIGRATIONS` |
| Security (4 + inventory) | `SECURITY`, `PRIVACY`, `LICENSE_COMPLIANCE`, `DEPENDENCY_INVENTORY`, `inventory/rust-deps-matrix-sdk-ffi.csv` (564 crates) |
| Testing (3) | `TEST_STRATEGY`, `UNREAD_REGRESSION_TESTS`, `INTEGRATION_TESTS` |
| Development (4) | `DEVELOPMENT_SETUP`, `CODE_CONVENTIONS`, `BUILD_AND_RELEASE`, `CI_CD` |
| Other | `docs/reference-notes/README.md` (clean-room notes policy), `scripts/validate-docs.sh` + `scripts/validate_docs.py` |

The interview-era documents (numbered PRD/architecture/licensing/roadmap/unread/plan/risk files and the first decision log) were merged into this structure and removed; their
decisions are preserved in `DECISION_LOG.md`. No application code, UI or placeholder implementations were created.

## 2. Validation performed (Section 16 checklist)

| # | Check | Result | How |
|---|---|---|---|
| 1 | All required documentation files exist | ✅ | `scripts/validate-docs.sh` — required-file list (67 paths) |
| 2 | Every major feature has a specification with all sections | ✅ | Validator checks 12 sections per spec in `docs/features/` |
| 3 | Architecture internally consistent | ✅ with fixes | Manual review; fixed during review: read position redesigned around timestamps (receipt timestamps ≠ event order, F-FFI-15); "server zero" rule restricted to rooms where the server can count (new E2x, S21, V-RS-6); room-list mark-as-read via `markRoomRead` (no latest event id in the room list) |
| 4 | Module dependencies documented | ✅ | MODULE_BOUNDARIES §1–3 (table, diagram, forbidden directions) |
| 5 | Important decisions have ADRs | ✅ | 14 ADRs incl. all required topics (monorepo, SDK integration, UniFFI vs C, SwiftUI state, persistence, unread source of truth, module boundaries, testing) + push, stickers, bots, licensing, iOS target |
| 6 | AGENTS.md actionable | ✅ | Mandatory procedure, ownership table, conventions, real commands with availability, forbidden patterns; the 10 required instructions are explicit (§0, §4, §11–13) |
| 7 | No contradictory requirements | ✅ | Superseded decisions are marked (D3, D8, D12, D27, D40 → D44, D46, D47, D48); stale references checked by the validator |
| 8 | Unresolved technical risks identified | ✅ | RISK_REGISTER (31 risks) + OPEN_QUESTIONS (31 validation items of which 2 resolved; 11 decision items, 4 decided in §10) |
| 9 | Prioritised roadmap | ✅ | ROADMAP M0–M10 with gates G-FFI and G-UNREAD |
| 10 | Entry criteria for implementation | ✅ | ROADMAP "Implementation entry criteria" + §6 below |

Validator output at the time of this report: `validate-docs: all checks passed` (it also checks links, ID references
D/ADR/F/V/Q/AC/S, ADR sections, statement labels and code fences).

## 3. Key architectural decisions
1. **Swift-first over the unmodified upstream FFI binary** (ADR-0002, D44). Verified that upstream FFI objects can't be extended by another crate (F-FFI-3); a Halo-owned UniFFI layer is the planned fallback behind the same ports (gate G-FFI).
2. **Halo-owned ports** are the stable contract; only `HaloMatrixAdapter` imports `MatrixRustSDK` (ADR-0004).
3. **Read-state reconciliation policy** (pure Swift, one function for the app and the NSE): server owns read positions and counts, SDK owns client counts, Halo owns only intents and notification records; badge = rooms needing attention, always recomputed (ADR-0007, D47).
4. **Push** via self-hosted Sygnal, `event_id_only`, NSE decrypt + local badge (ADR-0010). **Pushes are hints, never truth** (D65): Halo's Sygnal pushkin turns count-only pushes into background pushes and no push sets `aps.badge` (ADR-0015). The NSE has its own gate G-NSE at the end of M1 (ADR-0016).
5. **Stickers on the stable Matrix v1.19 image packs** (`m.room.image_pack`, `m.image_pack.rooms`) — a change from the interview's `im.ponies.*` plan after verifying the spec (ADR-0011, D48). Stickers v1 stays in the MVP (D45).
6. **Bots without bot changes**: strict versioned template parsers, the bot's existing reaction protocol (verified from its source), a derived task index that never claims authority (ADR-0012).
7. **GRDB** for app-owned data, file protection + field encryption (ADR-0006).
8. **Clean room + licence gate**: no GPL/LGPL/AGPL in the 564-crate SDK tree; MPL-2.0 only file-level (ADR-0013).

## 4. Outstanding questions (decisions for the founder)
| ID | Question | Needed by |
|---|---|---|
| Q-SDK-BUILD | When to build the SDK from source instead of the prebuilt package | M5 |
| Q-E2EE-STRATEGY | Room-key sharing strategy with unverified devices | M2 |
| Q-MAS-ACCOUNT | Native session list vs MAS account page | M5 |
| Q-BOT-OWNER | Ticking tasks owned by other members | M6 |
| Q-ACT-REFRESH | Visible "refresh from bot" command | M7 |
| Q-CI-MAC, Q-CRASH | macOS CI for releases; crash reporting before public release | M5 / M10 |

## 5. Items requiring technical validation (highest impact first)
| ID | What | Milestone |
|---|---|---|
| V-NSE-1/2/3 | NSE memory/time with the SDK; badge computation inside the NSE | M1 |
| V-RS-5, V-RS-1, V-RS-6 | Receipt coverage in sliding sync; RoomInfo update triggers; Synapse counting per mode in encrypted rooms | M1–M3 |
| V-ST-1/2 | Loading `m.room.image_pack` through the FFI, or the authenticated-GET fallback | M4 |
| V-SDK-1 | Prebuilt package version ↔ SDK commit/features (licence inventory accuracy) | M0 |
| V-SQL-1/2, V-CI-1 | Two SQLite copies; GRDB multi-process; GRDB on Linux | M0–M1 |
| V-PUSH-1/3/5 | Sygnal payload mapping; filtering entitlement approval (request early); count-only pushes as background pushes (ADR-0015) | M1 |
| V-APPLE-1, V-CI-1 | Apple platform facts used in the design; GRDB on Linux | M0 |
Full list: [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md).

## 6. Known risks (top)
T-NSE, T-RECEIPTS, T-FFI, T-STATE, T-XPROC, L1/L3 (licence drift / upstream relicensing), PROJ-1 (solo capacity). See [RISK_REGISTER.md](RISK_REGISTER.md).

## 7. Recommended implementation order
1. **M0 Foundation** — repo skeleton per DEVELOPMENT_SETUP; `infra/dev`; packages with empty-but-compiling targets only where needed by real code; adapter `SessionPort` + `RoomListPort` (password login, room count); V-SQL-1, V-CI-1, V-SDK-1, V-APPLE-1; boundaries + Linux CI.
2. **M1 Read-only client** + **NSE spike** (V-NSE-*), and submit the filtering-entitlement request.
3. **M2 Messaging.**
4. **M3 Read-state engine** (policy, outbox, NSE pipeline, scenario driver, auditor) → **gates G-UNREAD and G-FFI**. (G-NSE closes M1.)
5. **M4 Stickers v1** (V-ST-1 first week) → **M5 hardening = MVP**.
6. P2: M6 bot cards → M7 Activity → M8 search/saved → M9 gallery/export → M10 threads.

## 8. Entry criteria for Phase 1
- [x] Founder approves this documentation set (2026-11-19).
- [x] Q-BUNDLE decided (D63): namespace root `one.mbm.halo`, identifiers in DEVELOPMENT_SETUP §3.
- [x] Q-DEV-AUTH decided (D64: native password login in M0, MAS in M5).
- [x] ADR-0015 accepted with conditions (D65) and ADR-0016 accepted (D66).
- [x] Apple Developer membership available.
- [ ] Mac with the iOS 26 SDK — not yet; M0 started with its Linux part (ROADMAP "M0 without a Mac").
- [x] Homeserver domain available for the personal deployment (`infra/dev` runs on localhost).

## 9. Review (2026-11-19)
A full read of the documentation before Phase 1 found the issues below; each is fixed on this branch in its own commit.

| Area | Finding | Resolution |
|---|---|---|
| Read state | Server zero advanced the read position, so receipts for quiet messages could be skipped; `hasUnread` under E2 was undefined | `readPosTs` vs `notifiedThroughTs` split; `hasUnread` per mode; P9, P10, S07b ([matrix/UNREAD_STATE.md](matrix/UNREAD_STATE.md) §5) |
| Read state | C1 promised a server floor in encrypted rooms that no rule applied (and a floor would cause phantom unread, C4) | E3b marks counts approximate; encrypted-gap mention documented as a limitation; T-ENCGAP, S22 |
| Read state | Default "mentions" mode for groups puts most encrypted groups on E2x; S06 couldn't fire in that mode | Trade-off stated (UNREAD_STATE §9, NOTIFICATIONS FR-8); S06 pinned to all-messages mode |
| Concurrency | `.bufferingNewest(1)` on a multi-room stream would drop other rooms' updates | Lossless stream, coalesced per room id; `RoomReadInputsPart` and one source per room defined |
| Push | Synapse's count-only pushes become `aps.badge`-only pushes with stock Sygnal **[VERIFIED F-PUSH-1/2]** — the server's count would overwrite Halo's badge | ADR-0015 (proposed), V-PUSH-5, Q-PUSH-BADGE; V-PUSH-2 resolved as false |
| Push | Notifications shown without the NSE had no clearing path | Clearing by payload `room_id` once the room has no attention |
| Gates | NSE budget was a G-FFI criterion although Halo bindings wouldn't reduce it | ADR-0016 (proposed): separate gate G-NSE at the end of M1 |
| Consistency | Sticker prefs location, rollback vs SDK downgrade, Bot Activity FR-1 vs AC-A1, AC-TL-3, HaloFoundation layering, ADR-0014 vs D18, M0 gate list, MAS in M0 | Fixed; Q-DEV-AUTH added |
| Accuracy | Wrong `[VERIFIED]` citations; nine API names used as verified without a source | All checked at the pinned SDK rev: F-FFI-21/22; V-TL-1 resolved; dormant Sentry code noted in PRIVACY |
| Design | Badge and status tokens failed the 4.5:1 contrast rule; `attention` ≈ `warning` | New `on*` tokens and adjusted colours |
| Hygiene | 21 `[DECISION]` labels without IDs; risk IDs colliding with milestones/properties; stale `AGENTS.md §9` refs | D49–D62; risk prefixes `COMPAT-`/`PERF-`/`PROJ-`; refs fixed; validator now checks decision IDs and AGENTS § references |

## 10. Founder decisions (2026-11-19)
Approved by the founder; they don't block M0. The documentation set as a whole was approved the same day.

| Item | Decision | Recorded in |
|---|---|---|
| Q-BUNDLE | One consistent, project-owned namespace root for the app and all extensions: `one.mbm.halo` | D63; identifiers in [development/DEVELOPMENT_SETUP.md](development/DEVELOPMENT_SETUP.md) §3 |
| Q-DEV-AUTH | Native Matrix username/password login in M0; MAS deferred to M5 | D64; ROADMAP M0/M5; V-AUTH-1 |
| ADR-0015 | Accepted with conditions: custom Sygnal module converts count pushes into silent background pushes; the server never controls the badge; the local unread engine is the sole badge authority; the relay is a fallback only | ADR-0015, D65, AGENTS.md §4 principle 9 and §17 |
| ADR-0016 | Accepted: NSE evaluated at the end of M1, independently of G-FFI; acceptance criteria cover timeout handling, memory, extension termination, network failures and fallback behaviour | ADR-0016, D66, AC-NSE-1…6 (NOTIFICATIONS §11), ROADMAP G-NSE |
| Principle | Push notifications are synchronisation hints, not the source of truth; the local unread engine, backed by Matrix sync state, is the sole authority for unread counts and the badge | D65; AGENTS.md §4 principle 9 |
