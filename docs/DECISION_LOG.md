# Decision Log

Short, numbered product and architecture decisions (Dnn). Larger decisions get an ADR in
`docs/adr/`; this log links to them. **Superseded decisions stay listed and are marked**, so
history is never rewritten. Every document cites decisions by ID.

Legend: ✅ active · ⛔ superseded (see the replacing entry)

## Product and distribution
| ID | Decision | Status |
|---|---|---|
| D1 | First 12 months: personal / small circle via TestFlight. Long term: public App Store app | ✅ |
| D2 | Private repository, proprietary ("All rights reserved") | ✅ |
| D24 | Capacity: solo developer, part-time (~10–20 h/week) | ✅ |
| D25 | Minimum iOS 26 | ✅ ADR-0014 |
| D45 | Priorities: P0 = unread/read-state correctness; P1 = core messaging; **stickers v1 stays in the MVP** (confirms D14). P2 = sticker v2, bot cards, Bot Activity tab, productivity features | ✅ |

## Matrix foundation and architecture
| ID | Decision | Status |
|---|---|---|
| D3 | Own Rust FFI crate on top of unmodified matrix-rust-sdk | ⛔ by D44 (verified: upstream FFI types can't be extended from another crate) |
| D27 | Reuse matrix-sdk-ffi bindings + own crate in one XCFramework | ⛔ by D44 |
| D44 | **Swift-first, migrate later.** Halo's domain logic is Swift. The unmodified upstream `matrix-sdk-ffi` is consumed as a binary framework. **Only `HaloMatrixAdapter` imports upstream FFI types**; it implements Halo-owned port protocols. The validation gate G-FFI (M3) decides whether to replace it with Halo-owned UniFFI bindings over `matrix-sdk`/`matrix-sdk-ui`, without changes to the domain or feature modules | ✅ ADR-0002, ADR-0003, ADR-0004 |
| D4 | Homeserver: self-hosted Synapse with native Simplified Sliding Sync (MSC4186) | ✅ |
| D15 | Auth: OIDC (MAS) + legacy password; QR/emoji verification; recovery key | ✅ |
| D41 | SwiftUI: `@Observable` feature view models, service protocols, `AsyncStream`; constructor + Environment injection | ✅ ADR-0005 |
| D40 | App-owned data in one Rust-owned encrypted SQLite | ⛔ by D46 |
| D46 | App-owned data in one Swift-owned SQLite database (GRDB, MIT) in the App Group container, file protection plus field encryption with CryptoKit for content columns | ✅ ADR-0006 |
| D42 | Monorepo (`ios/`, `infra/`, `docs/`, later `core/`) | ✅ ADR-0001 |
| D43 | Calls: keep the MatrixRTC / Element Call widget path open; MVP only renders call events | ✅ |

## Unread, receipts, notifications (P0)
| ID | Decision | Status |
|---|---|---|
| D5 | App icon badge = number of rooms needing attention | ✅ |
| D6 | Read = event actually visible in the foreground for ≥ 0.5 s | ✅ |
| D7 | Public `m.read` by default; setting for `m.read.private` | ✅ |
| D8 | Own unread engine in Rust | ⛔ by D47 |
| D47 | **Read-state reconciliation layer in Swift** (`HaloDomain.ReadState`): a pure policy over SDK and server signals; it never recounts events itself in the MVP. Upgrade to an independent recount only if gate G-UNREAD fails | ✅ ADR-0007 |
| D9 | The badge is never incremented; it is always recomputed by one function used by both the app and the NSE | ✅ |
| D10 | Self-hosted Sygnal, `event_id_only`; request the notification-filtering entitlement | ✅ ADR-0010 |
| D11 | Read-elsewhere clearing: best effort via background pushes + full reconcile on foreground | ✅ |
| D17 | Until threads ship: thread events inline, unthreaded receipts | ✅ |

## MVP scope
| ID | Decision | Status |
|---|---|---|
| D14 | MVP = auth, E2EE, room list, timeline, text, push, unread, replies, edits, deletes, reactions, stickers v1 | ✅ (confirmed by D45) |
| D16 | Media: display all incoming; send images | ✅ |
| D29 | MVP bot support = generic HTML-subset rendering + view source only | ✅ |

## Stickers
| ID | Decision | Status |
|---|---|---|
| D12 | `m.sticker` + MSC2545 (`im.ponies.*`) packs, personal packs in account data | ⛔ by D48 |
| D48 | **Stickers use the stable spec image packs (Matrix v1.19)**: `m.room.image_pack` room state + `m.image_pack.rooms` account data; personal packs are a private room owned by the user; send `m.sticker`. Read legacy `im.ponies.*` packs (read-only) for compatibility | ✅ ADR-0011 |
| D13 | Animated: WebP/GIF/APNG only | ✅ |

## Bots
| ID | Decision | Status |
|---|---|---|
| D18 | Bot account and backend are never changed; the app talks to the bot only via Matrix messages; no LLM in the app; the bot backend is the source of truth for bot business data | ✅ ADR-0012 |
| D19 | `BotMessageRenderer` is a Swift UI-layer module, independent of the Matrix adapter | ✅ |
| D20 | Two layers: generic rendering + strict, versioned template parsers for allowlisted bots | ✅ |
| D21 | No tables/charts until a separately approved, backward-compatible bot change | ✅ |
| D22 | Checkbox → the existing 👍 reaction on the original confirmation event; pending until the bot confirms | ✅ |
| D23 | List rows map via (room, bot sender, entity id parsed from the bot's own "Added Task #N" event); otherwise read-only | ✅ |
| D26 | Bot Activity tab after the MVP (P2) | ✅ |

## P1/P2 data features
| ID | Decision | Status |
|---|---|---|
| D30 | Search: local index; **evaluate the upstream `SearchService` first** | ✅ |
| D31 | Bookmarks: private "Saved" room | ✅ |
| D32 | Backup: on-demand encrypted export | ✅ |
| D33 | Saved message = copy + origin header + permalink + origin ids | ✅ |
| D34 | Global media gallery from a local media index | ✅ |

## Quality, licensing, process
| ID | Decision | Status |
|---|---|---|
| D28 | Order after core messaging: unread hardening → stickers → bot template cards | ✅ |
| D35 | Unread tests: pure policy + property tests, Synapse scenarios, on-device auditor, replay | ✅ ADR-0009 |
| D36 | CI: Linux for docs, domain logic and Synapse scenarios; Apple builds on a local Mac | ✅ ADR-0009 |
| D37 | Clean-room, behaviour-only reference for Element X | ✅ ADR-0013 |
| D38 | Professional legal review before any public release | ✅ |
| D39 | Automated licence gate; generated acknowledgements screen | ✅ |
