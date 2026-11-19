# Phase 0 — Documentation Completeness Report

Date: 2026-11-19 · Branch: `claude/blissful-galileo-3400g9` · Status: **complete, awaiting approval for Phase 1**.

## 1. Files created

| Area | Files |
|---|---|
| Root | `AGENTS.md` (engineering contract), `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `LICENSE` (proprietary), `.gitignore`, `.github/workflows/docs.yml` |
| Product | `docs/README.md`, `PRODUCT_VISION.md`, `REQUIREMENTS.md`, `ROADMAP.md`, `GLOSSARY.md` |
| Decisions and tracking | `DECISION_LOG.md` (D1–D48, superseded entries kept), `adr/` (README, TEMPLATE, ADR-0001…0014), `OPEN_QUESTIONS.md`, `RISK_REGISTER.md`, `SOURCES.md`, this report |
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
| 8 | Unresolved technical risks identified | ✅ | RISK_REGISTER (28 risks) + OPEN_QUESTIONS (29 validation items, 8 open decisions) |
| 9 | Prioritised roadmap | ✅ | ROADMAP M0–M10 with gates G-FFI and G-UNREAD |
| 10 | Entry criteria for implementation | ✅ | ROADMAP "Implementation entry criteria" + §6 below |

Validator output at the time of this report: `validate-docs: all checks passed` (it also checks links, ID references
D/ADR/F/V/Q/AC/S, ADR sections, statement labels and code fences).

## 3. Key architectural decisions
1. **Swift-first over the unmodified upstream FFI binary** (ADR-0002, D44). Verified that upstream FFI objects can't be extended by another crate (F-FFI-3); a Halo-owned UniFFI layer is the planned fallback behind the same ports (gate G-FFI).
2. **Halo-owned ports** are the stable contract; only `HaloMatrixAdapter` imports `MatrixRustSDK` (ADR-0004).
3. **Read-state reconciliation policy** (pure Swift, one function for the app and the NSE): server owns read positions and counts, SDK owns client counts, Halo owns only intents and notification records; badge = rooms needing attention, always recomputed (ADR-0007, D47).
4. **Push** via self-hosted Sygnal, `event_id_only`, NSE decrypt + local badge (ADR-0010).
5. **Stickers on the stable Matrix v1.19 image packs** (`m.room.image_pack`, `m.image_pack.rooms`) — a change from the interview's `im.ponies.*` plan after verifying the spec (ADR-0011, D48). Stickers v1 stays in the MVP (D45).
6. **Bots without bot changes**: strict versioned template parsers, the bot's existing reaction protocol (verified from its source), a derived task index that never claims authority (ADR-0012).
7. **GRDB** for app-owned data, file protection + field encryption (ADR-0006).
8. **Clean room + licence gate**: no GPL/LGPL/AGPL in the 564-crate SDK tree; MPL-2.0 only file-level (ADR-0013).

## 4. Outstanding questions (decisions for the founder)
| ID | Question | Needed by |
|---|---|---|
| **Q-BUNDLE** | Bundle ID prefix / App Group / account-data namespace (needs a domain you control) | **before M0** |
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
| V-PUSH-1/3 | Sygnal payload mapping; filtering entitlement approval (request early) | M1 |
| V-APPLE-1 | Apple platform facts used in the design | M0 |
Full list: [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md).

## 6. Known risks (top)
T-NSE, T-RECEIPTS, T-FFI, T-STATE, T-XPROC, L1/L3 (licence drift / upstream relicensing), M1 (solo capacity). See [RISK_REGISTER.md](RISK_REGISTER.md).

## 7. Recommended implementation order
1. **M0 Foundation** — decide Q-BUNDLE; repo skeleton per DEVELOPMENT_SETUP; `infra/dev`; packages with empty-but-compiling targets only where needed by real code; adapter `SessionPort` + `RoomListPort` (password login, room count); V-SQL-1, V-CI-1, V-SDK-1, V-APPLE-1; boundaries + Linux CI.
2. **M1 Read-only client** + **NSE spike** (V-NSE-*), and submit the filtering-entitlement request.
3. **M2 Messaging.**
4. **M3 Read-state engine** (policy, outbox, NSE pipeline, scenario driver, auditor) → **gates G-UNREAD and G-FFI**.
5. **M4 Stickers v1** (V-ST-1 first week) → **M5 hardening = MVP**.
6. P2: M6 bot cards → M7 Activity → M8 search/saved → M9 gallery/export → M10 threads.

## 8. Entry criteria for Phase 1
- [ ] Founder approves this documentation set (or requests changes).
- [ ] Q-BUNDLE decided (bundle prefix, App Group, account-data namespace).
- [ ] Apple Developer membership and a Mac with the iOS 26 SDK available.
- [ ] Homeserver domain available for `infra/dev` / personal deployment.
