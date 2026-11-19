# Risk Register

L(ikelihood) / I(mpact): Low · Med · High. Reviewed at every milestone exit.

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
| T-PERF | SwiftUI timeline performance with media and animated stickers | Med | Med | Diff batching, off-main decoding, animation caps, perf tests | Dropped frames |
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
| L7 | Prebuilt binary contents differ from the inventory (features, commit) | Med | Med | V-SDK-1; build from source before external testers (Q-SDK-BUILD) |

## Matrix compatibility
| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| C1 | Servers without native sliding sync (public phase) | High | High | Clear unsupported-server message; target audience definition |
| C2 | Few clients support v1.19 image packs yet → Halo packs invisible elsewhere | High | Low | Stickers still render everywhere; legacy read support |
| C3 | Unencrypted packs surprise users | Med | Med | Notices (spec SHOULD) |
| C4 | Reaction-based bot protocol races | Med | Low | Pending state machine, confirmation rules |

## Performance
| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| P1 | Cold start slow for large accounts | Med | Med | Cache-first room list; NFR-1 measurement |
| P2 | Media cache growth | High | Low | Retention policy + storage screen |
| P3 | Search index growth (P2) | Med | Med | Evaluate upstream SearchService first |

## Maintenance / project
| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| M1 | Solo part-time capacity → slips/abandonment | High | High | Strict milestones, gates, early daily-driver use |
| M2 | Two ecosystems (Swift + Rust) | Med | Med | No Halo Rust unless G-FFI fails |
| M3 | Self-hosted infrastructure upkeep | Med | Med | One compose file, stock configs, backups |
| M4 | Bus factor 1 | High | Med | This documentation + AGENTS.md + scenario suite as specification |
