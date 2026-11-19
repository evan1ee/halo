# Halo — Feature Roadmap

Capacity assumption: solo, part-time (~10–20 h/week) (D24). Durations are rough calendar estimates and
include learning time. iOS 26+ (D25).

## MVP definition

The MVP is done when the founder switches their daily driver from Element X to Halo and the acceptance criteria in
the PRD §6 pass. Scope: PRD §4.1.

## Milestones

| # | Milestone | Content | Exit criteria | Est. |
|---|---|---|---|---|
| M0 | Foundations | Monorepo; `/infra` docker-compose (Synapse+MAS+Sygnal+Postgres); Rust workspace with `halo-ffi` depending on matrix-sdk-ffi; XCFramework build script; empty SwiftUI app plus NSE target; cargo-deny; proprietary LICENSE; CONTRIBUTING | A Swift app logs in by password, prints the room count; CI green | 3–4 wk |
| M1 | Read-only client | Session restore; SyncService; room list; timeline (text, notices, images, UTD placeholders); E2EE: verification, recovery key; **NSE spike** (decrypt and show one push; measure memory) | Can read all your rooms; push works for an encrypted DM | 6–8 wk |
| M2 | Messaging | Composer, replies, edits, deletes, reactions, typing, receipts display, send queue, media display (video/file/audio), image send | Daily use possible alongside Element X | 6–8 wk |
| M3 | **Unread correctness** | `halo-unread` engine, store, receipt outbox, visibility-based read, badge recompute in the app and NSE, notification clearing, `m.marked_unread`, per-room modes, auditor; Synapse scenario suite; property tests | AC-U1…U5 automated and green | 6–8 wk |
| M4 | Stickers v1 | MSC2545 packs, panel UI, favourites/recents, search, preview, send/render `m.sticker`, personal pack creation | AC-M3 | 4–6 wk |
| M5 | MVP hardening | OIDC/MAS login, device list, settings, acknowledgements, generic bot rendering + view source, perf (AC-M4), 7-day auditor soak (AC-U6) | **Daily-driver switch** | 4–6 wk |
| — | **MVP total** | | | **~7–10 months** |
| M6 | Bot cards | Template parsers (todo list, task added, reminder), task→event index, reaction checkbox protocol | Fixture suite green; manual end-to-end with the real bot | 3–4 wk |
| M7 | Search + saved | Evaluate upstream search_service → decide; local index; Saved room with origin metadata | Find a known message in an encrypted room | 5–7 wk |
| M8 | Media gallery + export | Media index, global gallery; per-room encrypted export | — | 4–6 wk |
| M9 | Threads + Activity tab | Thread UI, per-thread receipts in the engine; Activity tab | Unread scenarios with threads green | 5–7 wk |
| M10 | Public-release prep | Homeserver discovery and onboarding, privacy policy, legal review (D38), App Store compliance | Legal sign-off | — |
| P2 | Calls, on-device AI, structured bot content | | | — |

## Dependencies between milestones

```
M0 → M1 → M2 → M3 → M5(MVP)
           └──→ M4 ──┘
M3 → M9 (threads need the engine)       M5 → M6 → (Activity tab in M9)
M1 media cache → M4 stickers → M8 gallery
M7 index ↔ M8 media index share halo-store infrastructure
```

## Top technical risks per milestone (see the risk register)

- M0: UniFFI multi-crate library mode with matrix-sdk-ffi as a `lib` dependency (T1). **Spike in week 1.**
- M1: NSE memory and time limits with the Rust SDK (T2); the filtering entitlement request takes weeks, so send it in M1.
- M3: sliding-sync receipt coverage for rooms that aren't open (T4); cross-process consistency (T3).
- M4: animated sticker performance in long timelines (P2 risk).
- M7: index size and backfill cost; upstream search API stability.
