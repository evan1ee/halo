# Technical debt register

Scored list of code, architecture, test, tooling and dependency debt, re-scored 2026-11-25 at commit `155f745`. UX debt is in
[../design/UX_AUDIT.md](../design/UX_AUDIT.md); what the documents promise and the code lacks is in [../ROADMAP.md](../ROADMAP.md) §2.
Remove an item when its task is merged. Phases A–D of the 2026-11-22 plan are done except where an item below says otherwise.

**Scoring.** Impact (how much it slows work, 1–5) · Risk (what happens if we leave it, 1–5) · Effort (1 = hours, 5 = weeks).
**Priority = (Impact + Risk) × (6 − Effort).** ≥ 20 = do in the next milestone; 12–19 = schedule; < 12 = track.

## 1. Snapshot
| Area | Source lines | Note |
|---|---|---|
| Features (11 modules) | 13,627 | `FeatureTimeline` alone is 5,404 |
| HaloDomain · HaloApplication | 4,847 · 3,833 | Linux CI |
| HaloMatrixAdapter · HaloDesignSystem | 4,057 · 2,610 | contract, mapping and token tests |
| HaloPlatform · HaloPersistence | 1,036 · 822 | |
| App, NSE, Share | 1,926 · 214 · 249 | `HaloApp.swift` 816 |

Healthy signals: no `TODO`/`FIXME`, `print`, `as!` or `Task.detached` in production code; boundaries enforced; SDK and GRDB pinned exactly; contract runs leave nothing behind.

## 2. Register
| ID | Type | Debt | Evidence | I | R | E | **P** | Task |
|---|---|---|---|---|---|---|---|---|
| TD-01 | Errors | `try?` on calls that change state; the audit of Phase C isn't complete and no lint stops new ones | 122 `try? await` sites (sleeps and fakes excluded) | 3 | 5 | 3 | **24** | M18-8 |
| TD-07 | UI actions | `ActionState` was added but nothing uses it | no caller | 2 | 4 | 2 | **24** | M18-8 |
| TD-16 | Performance | Images decoded on the main thread, no decoded cache | `UIImage(data:)` ×13 | 4 | 5 | 3 | **27** | M19-1 |
| TD-17 | Performance | Timeline rows and the room list are rebuilt as a whole | `TimelineViewModel+Mapping.apply`, `.reset(list)` | 3 | 4 | 3 | **21** | M19-2, M19-3 |
| TD-18 | Testing | No migration fixtures, no visual regression tests | GA-09 | 3 | 4 | 3 | **21** | M18-5, M21-4 |
| TD-20 | Localisation | Literals in views, one app-level catalog that packages don't use | 12 of ~376 | 2 | 3 | 3 | **15** | M21-6 |
| TD-21 | Structure | Nine source files over 500 lines; `SettingsView` and `HaloApp` mix concerns | `wc -l` | 3 | 2 | 3 | **15** | M21-10 |
| TD-22 | Duplication | Three private error-to-text maps beside `HaloErrorCopy` | `UserProfileViewModel`, `RoomDetailsViewModel`, `NewChatViewModel` | 2 | 2 | 1 | **20** | M21-7 |
| TD-15 | Dependency | Upstream SDK gaps: classic sync without a filter (R-18), no queued `sendRaw`/`sendSticker` (R-21), direct HTTP for devices and password (ADR-0018/0019) | F-FFI-23 | 3 | 4 | 5 | **7** (higher if G-SCALE fails) | M17-4, §10 |

## 3. Tracking
Re-score at every milestone exit together with the [../RISK_REGISTER.md](../RISK_REGISTER.md) review.
