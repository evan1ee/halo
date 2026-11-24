# Technical debt register (2026-11-22)

A scored list of the technical debt in the codebase at commit `8da66aa` and a plan to pay it down **alongside** the M11–M15
feature work ([../ROADMAP.md](../ROADMAP.md)), not as a separate project. UX debt lives in
[../design/UX_AUDIT.md](../design/UX_AUDIT.md); this file covers code, architecture, tests, tooling, dependencies and docs.
Close an item by ticking its roadmap line; remove it here when merged.

**Scoring.** Impact (how much it slows work, 1–5) · Risk (what happens if we leave it, 1–5) · Effort (1 = hours, 5 = weeks).
**Priority = (Impact + Risk) × (6 − Effort).** ≥ 20 = do in the next milestone; 12–19 = schedule; < 12 = track.

## 1. Snapshot
| Area | Source lines | Test lines | Note |
|---|---|---|---|
| Features (7 packages) | 8,835 | 3,785 | `FeatureTimeline` alone is 2,941 |
| HaloApplication | 2,943 | 3,429 | well covered |
| HaloMatrixAdapter | 3,696 | 3,114 | contract + mapping tests |
| HaloDomain | 3,540 | 1,403 | Linux CI |
| App + NSE composition roots | 1,288 | **0** | `AppRoot.swift` 662, `HaloApp.swift` 419 |

Healthy signals: no `TODO`/`FIXME`, no `print`, `as!`, `fatalError`, `DispatchQueue` or `Task.detached` in production code; module
boundaries enforced by `scripts/check-boundaries.sh`; SDK and GRDB pinned exactly (`26.11.17`, `7.12.0`); `@unchecked Sendable`
used 3 times, 2 with a written justification.

## 2. Prioritised register

| ID | Type | Debt | Evidence | I | R | E | **P** |
|---|---|---|---|---|---|---|---|
| TD-15 | Dependency | **Upstream SDK gaps.** Classic sync without a filter (R-18), no queued `sendRaw`/`sendSticker` (R-21), direct HTTP for devices and password (ADR-0018/0019); each bump must recheck the workarounds | HANDOFF §5, OUTSTANDING_ISSUES | 3 | 3 | 5 | **6** |

## 3. Business justification (top items)
- **TD-01 errors:** a messenger that silently fails "Join", "Save name" or "Unignore" breaks the Honest-UI principle and makes beta
  bug reports unreproducible (nothing in the diagnostics). It is also needed by the M13 copy pass: there is no error to turn into copy.
- **TD-02 preferences:** every new setting (M13 first-run checklist, M15 What's New) would add another `AppPreferences()` call;
  a port now keeps settings testable and live.
- **TD-03 / TD-04 tests and CI:** external testers raise the cost of a broken build; the M14 UI test and a minimal macOS job are the
  cheapest insurance before Beta 2.
- **TD-05 / TD-06 consistency:** the D84 native feel depends on one token set and one formatting style; both make M13 diffs smaller.
- **TD-10 / TD-11 structure:** M12 rewrites the shell and M13 touches every timeline screen; splitting first avoids rewriting the
  same 1,400-line files twice.

## 4. Phased remediation (alongside feature work)

| Phase | With | Items | Done when |
|---|---|---|---|
| **A — quick wins (≈ 1 week)** | M11 | TD-06 swift-format + SwiftLint configs and the token rule in `prepush.sh`; TD-14 justifications or a `Mutex`; TD-09 roadmap cleanup (history to a "Done" appendix, one line per item, details in specs) | prepush runs lint with zero findings; ROADMAP queue fits on two screens |
| **B — foundations (≈ 2 weeks)** | M11–M12 | TD-05 (M11 itself); TD-02 `PreferencesPort` in `HaloDomain` + observable store in the app, all `AppPreferences()` call sites removed; TD-10 move bot-allowlist sync, diagnostics and cache logic into `HaloApplication` coordinators and replace Settings closures with a settings model factory during the M12 shell rewrite | `AppRoot` ≤ 300 lines, `SettingsView.init` ≤ 5 parameters, coordinators unit-tested |
| **C — reliability (≈ 2 weeks)** | M13 | TD-01 audit every `try?` on a state-changing call: return `Result`/throw to the view model, log once with `HaloLog`, show copy from the M13 error map; a grep gate for new `try? await` on port mutations. TD-07 an `ActionState` helper (in-flight flag, disables the control, cancels on disappear) for view-model actions. TD-11 split `TimelineViewModel` (composer, media, reactions, read tracking) and `TimelineView` (one file per private view) before the M13 timeline polish. TD-13 replace the sleep with a room-info subscription | zero `try?` on port mutations; double-tap test per action; no feature file > 600 lines |
| **D — safety net (≈ 2 weeks)** | M14–M15 | TD-03 `HaloUITests` golden path + accessibility audit (M14); TD-04 a manual-dispatch macOS workflow for the full build before every TestFlight upload (revisit D71); TD-08 `bot_action` table (append-only migration) | UI test green on every release candidate; macOS job green on the release commit |
| **Founder / upstream** | any | TD-12 (R-16 decision); TD-15 upstream PRs for `SyncSettingsV2` filter and queued raw sends | decided / SDK bumped |

## 5. Tracking
Each phase's items are in the ROADMAP queue under "Tech debt"; re-score this register at every milestone exit together with the
[../RISK_REGISTER.md](../RISK_REGISTER.md) review.
