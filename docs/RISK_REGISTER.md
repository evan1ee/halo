# Risk Register

L(ikelihood) / I(mpact): Low · Med · High. Reviewed at every milestone exit. IDs use prefixes (`T-`, `L`, `COMPAT-`, `PERF-`, `PROJ-`) that
don't collide with milestones (M0–M22), priorities (P0–P2), test properties (P1–P10) or unread causes (C1–C13).

## Technical
| ID | Risk | L | I | Mitigation | Early signal |
|---|---|---|---|---|---|
| T-FFI | Upstream FFI lacks data needed for correctness or stickers | Med | High | Ports + gate G-FFI; option B for state fetch; upstream contributions | V-ST-1, V-RS-* failures |
| T-NSE | NSE exceeds memory/time with the Rust SDK | Med | High | M1 spike; lightweight runtime; minimal NSE work; cached badge fallback | V-NSE-1 |
| T-RECEIPTS | Own receipts from other devices not delivered for rooms outside subscriptions | Med | High | Server-zero rule (E2); reconcile triggers; V-RS-5 | Scenario S02/S04 |
| T-STATE | Custom room state (image packs) not loadable via the FFI | High | Med | Option B (authenticated GET) behind `RoomPort`; upstream PR | V-ST-1 |
| T-XPROC | App ↔ NSE races on `halo.sqlite` | Med | High | Monotonic upserts, PK de-dup, Darwin notify, tests P7/P8 | Auditor version conflicts |
| T-SQLITE | Two SQLite libraries in one process misbehave | Low | High | Never share files; M0 smoke test | V-SQL-1 |
| T-CHURN | Upstream API churn makes bumps expensive | High | Med | Adapter-only changes; monthly bumps at most | Bump > 1 day |
| T-PERF | SwiftUI timeline performance with media and animated stickers (photos are decoded on the main thread and every row is rebuilt per change today, GA-15, GA-16) | High | High | M19-1 image pipeline, M19-2 incremental rows, G-PERF | Dropped frames, MetricKit hangs |
| T-SCALE | Classic sync without a filter is too slow or heavy on real accounts (hundreds of rooms, very large federated rooms) | Med–High | Very high | Measure first (M17-4), G-SCALE before M19, upstream filter PR, Q-SYNC-SCALE | First sync > 60 s; memory kills |
| T-IDENTITY | A contact's identity changes and Halo says nothing; a refused send looks like a network error | High (today) | High | M18-1, M18-2 | Interop matrix; security review |
| T-RECOVER | A damaged store or a restored backup without its keys leaves the app unusable | Low–Med | High | M18-4, M18-5 | Storage errors in diagnostics |
| T-LIVETIME | Nothing in the field is measurable: no MetricKit or signposts | High (today) | Med | M17-1, M17-2 before Beta 1 | Beta reports that can't be reproduced |
| T-BADGEPUSH | Synapse's count-only pushes set the server's count on the icon (stock Sygnal), undoing Halo's badge after every read | High (verified behaviour) | High | ADR-0015 (accepted): pushkin strips `aps.badge`; relay only as fallback; foreground re-set; device checklist | Icon differs from Halo's count while backgrounded |
| T-PUSHKIN | A Sygnal bump changes the internal pushkin API and breaks Halo's pushkin | Med | Med | Pin Sygnal in `infra/`; pushkin tests in CI on every bump; relay fallback (ADR-0015) | `pushkin.yml` red |
| T-ENCGAP | Mentions in encrypted mentions-only rooms (the default for groups) missed when they fall into a timeline gap and no push arrives | Med | Med | E4 via push; reconcile on room open; auditor `SERVER_BLIND`; S22 pins the behaviour | Auditor `SERVER_BLIND` counts |
| T-SKEW | Timestamp ordering wrong under federation clock skew | Low | Med | Timeline order index when available (V-RS-3); tests S18 | Auditor |
| T-BOTFMT | Bot message format changes break parsers | Med | Low | Strict versioned parsers + fallback; fixture sync | Unparsed-bot-message counter |

## Licensing / legal
| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| L1 | Copyleft crate enters via an SDK bump | Med | High | Inventory diff + allowlist on every bump |
| L2 | Claim of derivation from Element X | Low | High | Clean-room policy (ADR-0013), behaviour-only notes, independent design |
| L3 | Upstream relicenses the SDK away from Apache-2.0 | Low–Med | Very high | Pinned Apache-licensed revs remain usable; watch upstream; fallback: maintain the last Apache rev ⚖️ |
| L4 | Missing attribution in a shipped build | Med | Med | Generated notices + release checklist |
| L5 | Export compliance / App Store problems with encryption | Med | Med | Legal review (V-LEGAL) |
| L6 | Trademark confusion (Matrix/Element) | Low | Med | Neutral name and icon |
| L7 | Prebuilt binary contents differ from the inventory (features, commit) | Low | Med | V-SDK-1 resolved: the release commit names the SDK commit and the inventory is checked there by `licenses.yml`; the binary is still built by Element, so build from source before external testers (Q-SDK-BUILD) |

## Matrix compatibility
| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| COMPAT-1 | ~~Servers without native sliding sync~~ closed: classic sync is used (D74, D81). Remaining: servers or rooms too large for it (T-SCALE) | — | — | — |
| COMPAT-5 | Only Synapse in `infra/dev` is tested; other servers (public instances, Conduit family, Dendrite) differ in push rules, counts or MAS | Med | Med | V-INTEROP-1, V-OIDC-1; say which servers are tested |
| COMPAT-2 | Few clients support v1.19 image packs yet → Halo packs invisible elsewhere | High | Low | Stickers still render everywhere; legacy read support |
| COMPAT-3 | Unencrypted packs surprise users | Med | Med | Notices (spec SHOULD) |
| COMPAT-4 | Reaction-based bot protocol races | Med | Low | Pending state machine, confirmation rules |

## Performance
| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| PERF-1 | Cold start slow for large accounts | Med | Med | Cache-first room list; NFR-1 measurement |
| PERF-2 | Media cache growth | High | Low | Retention policy + storage screen |
| PERF-3 | Search index growth (P2) | Med | Med | Evaluate upstream SearchService first |

## Maintenance / project
| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| PROJ-1 | Solo part-time capacity → slips/abandonment | High | High | Strict milestones, gates, early daily-driver use |
| PROJ-2 | Two ecosystems (Swift + Rust) | Med | Med | No Halo Rust unless G-FFI fails |
| PROJ-3 | Self-hosted infrastructure upkeep | Med | Med | One compose file, stock configs, backups |
| PROJ-4 | Bus factor 1 | High | Med | This documentation + AGENTS.md + scenario suite as specification |
| PROJ-5 | The app is correct but feels unfinished or non-native, so testers fall back to their old client (UX_AUDIT) | High | High | D84 north star; M21; moderated first-run test (AC-UX-5); Beta 2 gate |
| PROJ-6 | App Store review rejects the build (privacy manifest, user-generated content rules: report/block, account deletion path) | Med | High | M20-7 report (missing today, GA-22); ignore user exists; M22-3 privacy; review server (Q-REVIEW); no account creation in the app (Q-SIGNUP) |
| PROJ-7 | The push gateway becomes a service others depend on (uptime, certificates, abuse, cost) | High at 1.0 | High | M22-1: monitoring, key-rotation drill, capacity, on-call rule; push health shown in Settings |
| PROJ-8 | Scope grows again and quality work slips | Med | High | R/C/P classes, C never delays; Q-SCOPE |
