# Halo — Session Handoff

Last updated: 2026-11-22 · Branch: `main` · PRs #1–#51 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Roadmap / Autonomous Loop:** functional roadmap M0–M10 done. **New phase M11–M15 (D84, Apple-native UX + ship readiness) added to the queue** in [docs/ROADMAP.md](docs/ROADMAP.md), backed by [docs/design/UX_AUDIT.md](docs/design/UX_AUDIT.md); next item is M11 (design-system foundation). Founder-blocked items in §5.
- **Milestones:** M0–M4, M6–M10 done (G-FFI & G-UNREAD evaluated and recommended **pass** in [docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md), awaiting founder confirmation); M5 done except Beta/Release push gateway + TestFlight and the 7-day AC-U8 soak. Dev Mac: Xcode 27.2, Swift 6.4.2, simulator `iPhone Air` (`HALO_SIM="iPhone Air"`).
- **Codebase review ([docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md)) & outstanding issues ([docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md)):** all 22 executable review findings FIXED; all verifiable items closed with tests; 5 founder decisions remain in §5.
- **Checks:** `HALO_SIM="iPhone Air" scripts/prepush.sh` passes (SwiftLint skipped: not installed/configured); `python3 -I tools/server-rules/check_server_rules.py` 16/16 `ok`; `tools/scenario-driver/run_scenarios.py` 28/28 `ok`; `ServerReadStateScenarioTests/realServerScenarios` passes; `AdapterContractTests/messageSearch` passes (`13.14s`); `infra/dev/smoke-mas.sh` + `AdapterContractTests/oidcDiscovery` pass (`0.821s`); **physical iPhone 16 verified live (`F-DEV-1`, `F-DEV-2`: 100/100 G-NSE soak, peak 7.40 MB, p95 144 ms, fault-injection + post-kill cold-start recovery)**.
- **CI:** PRs #1–#51 merged. Linux CI covers Foundation, Domain, TestSupport, Application; adapter, persistence, platform, features and the app are validated on Mac via `scripts/prepush.sh` (D71).

## 2. Completed work (last 3 sessions)
Summary only; details in `git log` and [docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md) §13.
- **Module layout proposal (this change, docs only):** [docs/adr/0022-module-layout-v2.md](docs/adr/0022-module-layout-v2.md) (Proposed): two manifests (`HaloCore` Linux / `HaloApple`), logic moved to its owning layer (`TimelineReadTracker` → domain, preferences port, routes → `HaloApplication`), new `FeatureSearch`/`FeatureProfile`/`FeatureMedia`/`FeatureComposer`/`HaloBotRendering`, `App/{Composition,Resources,Support}`, doc path fixes; TD-16. Module naming rule (`Halo<Layer>`, `Feature<Area>`, never a type's name) documented in MODULE_BOUNDARIES §1.
- **Tech-debt register (this change, docs only):** new [docs/development/TECH_DEBT.md](docs/development/TECH_DEBT.md) — 15 scored items (TD-01…15; top: silent `try?` on state-changing calls, preferences without a port, untested composition roots/UI, CI covering 4 of 12 packages) and a 4-phase plan riding on M11–M15, queued in ROADMAP "Tech debt".
- **UX & ship-readiness roadmap (D84, this change, docs only; checks run: `scripts/validate-docs.sh` and `check_handoff.py structure` pass; `prepush.sh` not run — no code changed):**
  - New [docs/design/UX_AUDIT.md](docs/design/UX_AUDIT.md): 16 UX findings (UX-01…16) and 7 ship-readiness findings (SR-01…07) with code evidence at `8da66aa`.
  - ROADMAP: milestones M11 design system · M12 navigation · M13 core-flow polish · M14 accessibility & localisation · M15 ship readiness, a "Ship-ready definition" and a release plan (Beta 1 → Beta 2 → 1.0 → M16 backlog).
  - REQUIREMENTS R-UX-* / R-SHIP, AC-UX-1…12, NFR-9/10; DESIGN_SYSTEM §1 principle 5, §11 Apple-native patterns, §12 voice and tone; NAVIGATION drift note; SCREEN_SPECIFICATIONS S14 priming + S15 checklist; SETTINGS rows; PRIVACY §5, TEST_STRATEGY §7/§7b/§8, BUILD_AND_RELEASE §4 steps 8–9; RISK PROJ-5/6; D85 single-stack navigation (founder, supersedes D50; NAVIGATION §1, S3, S6, AC-UX-3/4 updated); Q-BRAND, Q-ONBOARD-SERVER, Q-L10N, Q-APPSTORE.
- **App-switcher privacy blur (`8da66aa`, `D61`, `SECURITY §4`):**
  - Added `AppPreferences.privacyBlur` (default `true`, unit-tested in `AppPreferencesTests.privacyBlur`), Settings → Privacy → "Hide content in app switcher" toggle, and the `.ultraThinMaterial` privacy veil in `HaloApp` whenever `scenePhase != .active`.

## 3. Key decisions
Full list: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (D1–D85), [docs/adr/README.md](docs/adr/README.md).
- **D73 / D74:** classic Matrix sync (`syncOnceV2`, `slidingSyncVersionBuilder(.none)`) is the authoritative unread source.
- **D78 (R-01) / D79 (R-07):** SDK counts decide in encrypted rooms (`ENC_SERVER_ONLY` → no unread); E1/E1b yield to positive SDK counts once the SDK applied the read position.
- **D80 / ADR-0020 (R-06):** identity and timeline-index read ordering, `read_intent.timeline_order` (v8), `INTENT_STALE` on confirmed intents (revises D47, D72).
- **D81 (R-17):** removed native sliding-sync gate at server discovery and password login (amends AUTHENTICATION FR-5).
- **D82 / ADR-0021 (founder, supersedes D5):** app icon badge shows total unread messages across rooms needing attention (`BadgeCalculator.badge` sums `RoomReadState.badgeCount` for `attention == true`).
- **D85 (founder, supersedes D50):** single `NavigationStack`, Messages-style (avatar → Settings, compose, more menu with filters/Stickers/Activity, searchable list); resolves Q-NAV-SHELL.
- **D84 (founder direction):** Halo should feel like a first-party Apple app (system components, iOS 26 materials, Apple patterns) with its own identity; drives M11–M15.
- **D83 (founder, refines D34 & D50):** global media gallery is surfaced as a preset virtual room entry in the room list (not a tab); purely a local UI entry, not a Matrix room (no server room ID, no sync state, excluded from unread counts and badge).

## 4. Modified files (this push)
- **Docs (new):** `docs/design/UX_AUDIT.md`, `docs/development/TECH_DEBT.md`, `docs/adr/0022-module-layout-v2.md`, `docs/architecture/MODULE_BOUNDARIES.md`.
- **Docs (updated):** `docs/ROADMAP.md`, `docs/REQUIREMENTS.md`, `docs/DECISION_LOG.md`, `docs/OPEN_QUESTIONS.md`, `docs/RISK_REGISTER.md`, `docs/PRODUCT_VISION.md`, `docs/README.md`, `docs/design/DESIGN_SYSTEM.md`, `docs/design/NAVIGATION.md`, `docs/design/SCREEN_SPECIFICATIONS.md`, `docs/features/SETTINGS.md`, `docs/security/PRIVACY.md`, `docs/testing/TEST_STRATEGY.md`, `docs/development/BUILD_AND_RELEASE.md`, `HANDOFF.md`.

## 5. Outstanding issues
Non-founder limits and environment notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Needs the founder**
- 👤 **Gate confirmations:** confirm **G-FFI**, **G-UNREAD**, and **G-NSE** pass outcomes ([docs/testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md) §4; all S01–S29 automated + real-server + iPhone 16 `F-DEV-1`/`F-DEV-2` 100-push G-NSE checks are green).
- 👤 **R-14 (filtering entitlement):** NSE delivers silent empty passive content for suppressed/no-event pushes; request Apple's `com.apple.developer.usernotifications.filtering` entitlement (V-PUSH-3) for complete suppression.
- 👤 **R-16 (DB field encryption):** decide whether to implement AES-GCM field encryption using `KeychainItem.haloDatabaseKey` for `draft.body` and `bot_task.title/detail`, or accept plaintext under `completeUntilFirstUserAuthentication` with a new ADR.
- 👤 **R-18 & R-21 (upstream SDK gaps):** pinned `matrix_sdk_ffi.swift` (`26.11.17`, F-FFI-23) `SyncSettingsV2` has no filter (`lazy_load_members` / timeline limit) and `Timeline` has no queued `sendRaw`/`sendSticker`; requires upstream `matrix-rust-sdk` PR + SDK pin bump.
- 👤 **R-24 (pushkin & Beta/Release push gateway):** decide whether to build the `infra/sygnal/` Halo pushkin or amend ADR-0015, and configure the Beta/Release push gateway + APNs keys + TestFlight.
- 👤 **ADR-0022 (module layout v2):** accept, amend or reject; step 1 can ride on M11.
- 👤 **New UX/ship questions (D84):** **Q-BRAND** (icon/artwork), **Q-ONBOARD-SERVER**, **Q-L10N**, **Q-APPSTORE** — all in [docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md).
- 📱 **Long-horizon physical device soak:** 7-day AC-U8 daily-driver soak (and Release/TestFlight G-NSE spot check once TestFlight is configured).

## 6. Next steps
Queue: [docs/ROADMAP.md](docs/ROADMAP.md) §"Remaining work" (M11 onward).
1. **M11 design-system foundation** together with tech-debt Phase A (TD-06 lint/format, TD-14, TD-09 roadmap cleanup): asset catalogue with DESIGN_SYSTEM §2 colour tokens + placeholder AppIcon, token types, contrast test, shared components (`RoomRow`, `UnreadIndicator`, `Banner`, `LoadingState`, `ErrorState`, `EmptyState`), `HaloFeedback`, then replace raw colours/fixed sizes and add `scripts/check-design-tokens.sh` (AC-UX-1/2). One PR (big feature, D75).
2. **M12** single-stack shell per D85 ([docs/design/NAVIGATION.md](docs/design/NAVIGATION.md) §1): compose button, more menu, `.searchable` list, pushed Settings/Activity/Stickers, one router, state restoration.
3. Founder items in §5 (gates, R-14, R-16, R-18/R-21, R-24, new Q-items); 7-day AC-U8 soak on a signed device build.

## 7. Next Session Prompt
```text
Read AGENTS.md, HANDOFF.md, docs/design/UX_AUDIT.md and docs/ROADMAP.md
(sections M11–M15, "Ship-ready definition", "Release plan").
M0–M10 are done; the new phase makes Halo feel like an Apple-native app
and ship-ready (D84, DESIGN_SYSTEM §1, §11, §12).

Task: start M11 (design-system foundation) on branch feat/m11-design-system.
1. ios/App/Assets.xcassets: colour tokens of DESIGN_SYSTEM §2 (light/dark/
   Increase Contrast), AccentColor, placeholder AppIcon (Q-BRAND open).
2. HaloDesignSystem: HaloColor/Spacing/Radius/Motion/Typography, the contrast
   unit test (AC-UX-2), components of §7 with #Previews, HaloFeedback.
3. Replace raw colours and fixed font sizes in Features/App; add
   scripts/check-design-tokens.sh to scripts/prepush.sh (AC-UX-1).
4. Walk every screen in the simulator (light/dark, AX5) and attach screenshots.
Navigation (M12) follows D85: single stack, no tab bar; keep it for after M11.

Verification on this Mac:
- HALO_SIM="iPhone Air" scripts/prepush.sh
- scripts/validate-docs.sh
- Update HANDOFF.md in the last commit before every git push (AGENTS.md §18).
```
