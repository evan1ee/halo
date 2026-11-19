# Halo — Risk Register

Scale: L(ikelihood) / I(mpact) = Low · Med · High. Owner: the founder unless noted.

## Technical

| ID | Risk | L | I | Mitigation | Trigger / check |
|---|---|---|---|---|---|
| T1 | Using `matrix-sdk-ffi` as a Rust `lib` dependency and adding our own UniFFI crate in one static library doesn't work cleanly (duplicate scaffolding, runtime setup, symbol clashes) | Med | High | Spike in M0 week 1. Fallback: write `halo-ffi` against `matrix-sdk`/`matrix-sdk-ui` directly for only the APIs we need, or ship two separate frameworks | Spike result |
| T2 | NSE memory/time limits exceeded with the Rust SDK (crypto store open, decryption) | Med | High | Lean NSE features; no timeline; measure in M1 on the oldest supported device; profile with Instruments | NSE killed / jetsam logs |
| T3 | Cross-process races between the app and the NSE on `halo.sqlite` and the SDK stores → corruption or lost updates | Med | High | SQLite WAL + a cross-process file lock; `version` checks; recompute instead of incremental writes; scenario tests with the NSE path simulated | Auditor "version conflict" events |
| T4 | Sliding-sync receipts extension doesn't deliver receipts for every room we need | Med | High | Configure the extension per list; server-zero rule as a backstop (doc 05 §4 rule 3); scenario 1 and 4 | Scenario failures |
| T5 | The filtering entitlement is refused or delayed | Med | Med | Fallback generic notifications; reduce noise with push rules on the server where possible | Apple response |
| T6 | Upstream FFI API churn breaks Swift code at every bump | High | Med | Thin service layer (only HaloKit touches FFI types); monthly bumps at most; pin the rev | Bump effort > 1 day |
| T7 | Background execution limits delay "read elsewhere" clearing | High | Low | Best effort plus reconcile on foreground (accepted, D11) | — |
| T8 | Binary size / build time of the Rust static library | Med | Low | Strip, LTO, turn off unneeded default features; cache build artefacts | App > 150 MB |
| T9 | Timeline performance in SwiftUI with large rooms and animated stickers | Med | Med | Diff batching, frame coalescing, ImageIO decode off the main thread, pause offscreen animations | Dropped frames in Instruments |

## Licensing / legal

| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| L1 | A copyleft dependency enters through a transitive update | Med | High | cargo-deny gate; inventory diff per bump |
| L2 | A claim that Halo derives from Element X (AGPL) | Low | High | Clean-room policy, behaviour-only notes, an independent architecture, no fork imports; ⚖️ review |
| L3 | matrix-rust-sdk relicensed away from Apache-2.0 in future | Low–Med | Very high | Pinned Apache revs keep their licence; watch upstream; fallback plan: maintain a fork of the last Apache rev ⚖️ |
| L4 | Missing attribution in the shipped app | Med | Med | Generated acknowledgements; release checklist |
| L5 | Encryption export compliance / App Store review problems | Med | Med | Legal review before public release; correct Info.plist declarations |
| L6 | Trademark problems with the name or branding ("Matrix", "Element") | Low | Med | Neutral product name; descriptive use only |

## Matrix compatibility

| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| C1 | Homeservers without native sliding sync (relevant for the public phase) | High (public) | High | Personal phase: own Synapse. Public: detect and show a clear "unsupported server" message |
| C2 | MSC2545 image packs are unstable (`im.ponies.*` prefixes, no final spec) | Med | Med | Read both stable and unstable keys if a stable version appears; write the widely used unstable format; isolate it in `halo-stickers` |
| C3 | Element clients don't show pack-based sticker *pickers* (stickers still render) | High | Low | Accepted; cross-client rendering is what counts |
| C4 | Bot template formats change (the bot is owned by the founder, but its strings aren't a contract) | Med | Med | Versioned strict parsers; fallback to the generic renderer; fixture tests synced from the bot repo |
| C5 | Reaction-based bot interactions race (sync delays, duplicate events) | Med | Low | Pending state machine; confirm only on an authoritative bot event (D22) |
| C6 | Threads/receipt semantics change (MSC3771/3773 behaviour across servers) | Low | Med | Engine isolated; scenario tests per server version |

## Performance

| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| P1 | Cold start of the room list for large accounts | Med | Med | Cached room list from the SDK store; AC-M4 measured in CI on the simulator before release |
| P2 | Search index growth (P1) | Med | Med | Index text only, cap per room, compaction; evaluate upstream Tantivy first |
| P3 | Media cache storage growth | High | Low | LRU with a size cap; user-visible storage settings |

## Maintenance / project

| ID | Risk | L | I | Mitigation |
|---|---|---|---|---|
| M1 | Solo part-time capacity → the MVP slips beyond 12 months or is abandoned | High | High | Strict milestone order; MVP cuts already made; switch daily drivers early (M2 alongside Element X) |
| M2 | Knowledge of two languages and toolchains (Rust + Swift) slows progress | Med | Med | Keep Rust code small (unread, store, stickers); everything else in the upstream FFI |
| M3 | Running your own infrastructure (Synapse, MAS, Sygnal) takes time | Med | Med | One docker-compose; backups; keep to stock configs |
| M4 | Bus factor 1 | High | Med | Decision log + docs (this set); the scenario suite works as a specification |
