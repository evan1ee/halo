# Decision Log (interview in progress)

Status: interview complete (v0.1). Documents 01–07 in docs/ are derived from this log.

## Product & distribution
- D1  First 12 months: personal / small circle (TestFlight). Long term: grow into a public App Store app.
- D2  Private repository, proprietary. Replace MIT LICENSE with "All rights reserved".

## Matrix foundation
- D3  Own Rust FFI crate (UniFFI) depending on unmodified upstream matrix-rust-sdk (Apache-2.0). No fork.
- D4  Homeserver: self-hosted Synapse with native Simplified Sliding Sync (MSC4186); doubles as test bench.
- D15 Auth: OIDC (MAS) + legacy password; QR/emoji verification; recovery-key backup restore.

## Unread / notifications (P0)
- D5  App icon badge = number of rooms needing attention (not message total).
- D6  Read = latest event actually visible in foreground (~0.5 s dwell); receipt sent then.
- D7  Public m.read receipts by default, toggle for m.read.private.
- D8  Own unread engine in the Rust crate on top of SDK receipts/events; per-room {unread, mentions,
      confidence}; on gap -> "uncertain", fall back to server counts, backfill.
- D9  Badge never incremented; always recomputed from shared store by the same function in app and NSE.
- D10 Self-hosted Sygnal, event_id_only payloads; request com.apple.developer.usernotifications.filtering
      early; placeholder fallback without it.
- D11 Read-elsewhere clearing: best effort via background pushes + full reconcile on foreground/refresh.

## Stickers (P0)
- D12 Send standard m.sticker; packs as MSC2545 image packs (user packs in account data, room packs in
      state); favorites/recents in own account-data key.
- D13 Animated: WebP/GIF/APNG only; convert on import.

## MVP scope
- D14 MVP = login, E2EE, room list, timeline, text, push, correct unread/badges, replies, edits, deletes,
      reactions, stickers v1. Threads later.
- D16 Media: receive/display all; send images from photo picker. Video/file send, gallery later.
- D17 Until threads ship: thread messages inline as replies; unthreaded receipts for unread.

## Bot integration
- D18 Existing bot account & backend unchanged. App talks to bot only via Matrix messages. No LLM in app (MVP).
      Bot backend is source of truth for bot business data.
- D19 BotMessageRenderer: Swift UI-layer module, independent of Rust core; render only on reliable
      recognition; always offer raw view; graceful fallback.
- D20 Two layers: generic HTML-subset rendering for all bot messages + strict, versioned template parsers
      for allowlisted bot user IDs, tested against fixtures from the bot repo.
- D21 No tables/charts in MVP; no inference from free text. Future: optional structured field in bot
      messages via separately approved, backward-compatible bot change.
- D22 Checkbox -> existing 👍 reaction on original confirmation event; pending until bot ack/updated list;
      retry on failure; dedupe while pending; reaction delivery != completion.
- D23 List rows map to (room_id, bot sender, parsed entity id from bot's own "Added Task #N" event).
      Never react to the list message; missing event -> read-only "Not available".

## Findings from evan1ee/matrix-bot (MIT)
- Matrix output = plain body + HTML subset (b i u code pre p ul ol li blockquote a br, plus del in todo views).
- Interactive "actions" (buttons) are dropped on Matrix.
- Reactions: 👍 done, 👎 delete, 😝 +1 day, 🎉 celebrate; only on single-entity confirmation messages
  registered in reaction_targets.

## Capacity & platform
- D24 Solo, part-time (~10–20 h/week).
- D25 Minimum iOS 26.
- D26 Activity tab deferred to post-MVP.
- D27 Rust layer = upstream matrix-sdk-ffi (pinned git rev, unmodified, used as `lib` dependency) + own
      halo-* crates, one XCFramework.
- D28 Order after core messaging: unread correctness → stickers → bot template cards.
- D29 MVP includes only generic bot rendering (HTML subset) + view source.

## P1 features
- D30 Search: local index of decrypted messages (encrypted store) with optional backfill.
      Verified: upstream matrix-sdk-ffi ships `search_service` (Tantivy, feature experimental-search) —
      evaluate it before building own FTS5.
- D31 Bookmarks: private "Saved" Matrix room.
- D32 Backup: on-demand encrypted export of selected rooms to Files/iCloud Drive.
- D33 Saved message = copy + visible origin header + matrix.to permalink + custom field with original
      room/event id; encrypted media reuses original mxc + key.
- D34 Global media gallery from a local media index (post-MVP).

## Quality, licensing, architecture
- D35 Unread testing: pure engine + property tests, Synapse scenario tests, on-device auditor, sync replay.
- D36 CI: Linux GitHub Actions for Rust/Synapse; XCFramework, iOS tests and TestFlight from local Mac.
- D37 Clean room: behaviour-only reference for Element X (AGPL); prose notes only; no Element X code in
      repo or AI prompts; nothing imported from the old fork. Policy in CONTRIBUTING.md.
- D38 Professional legal review before any public release.
- D39 cargo-deny licence allowlist in CI; reviewed Swift package list; generated acknowledgements screen.
- D40 All app-owned data in one encrypted SQLite DB owned by the Rust core, in the App Group container.
- D41 SwiftUI: @Observable feature view models + thin service protocols + AsyncStream; constructor/Environment DI.
- D42 Monorepo: /core, /ios, /infra, /docs.
- D43 Calls: keep MatrixRTC / Element Call widget path open; MVP only renders call events.

## Verified facts (2026-11-19)
- matrix-rust-sdk @7ff8855: Apache-2.0; matrix-sdk-ffi Apache-2.0, `publish = false`, crate-type includes `lib`.
- iOS dependency tree of matrix-sdk-ffi: 552 crates, no GPL/LGPL/AGPL; MPL-2.0 = uniffi*, eyeball-im, imbl*.
  See docs/licensing/rust-deps-matrix-sdk-ffi.csv.
- SDK ReadReceipts keeps only 10 unmatched ("pending") receipts per room.
- Element X iOS: AGPL-3.0 + separate commercial licence.
