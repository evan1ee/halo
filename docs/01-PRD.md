# Halo — Product Requirements Document

Status: v0.1 (from requirements interview, 2026-11-19). Decision IDs (Dnn) refer to `docs/decisions.md`.

## 1. Product vision

Halo is an independent, proprietary iOS Matrix client. It is built for people who live in Matrix every
day and want it to be **trustworthy** (an unread badge that is never wrong), **fun** (a sticker
experience like Discord's) and **personal** (rich, native rendering of your own assistant bots,
your own message archive, search and media library).

Halo is not a fork of Element X and does not aim to copy it. It aims to match Element X on everyday
essentials and be clearly better in four areas:

1. **Correct unread and notification state.** This is the main differentiator, and it is designed into the architecture.
2. **Stickers.** A Discord-style sticker panel that works with other clients (`m.sticker` + MSC2545).
3. **Native bot cards.** Messages from known bots render as native SwiftUI cards, with no bot changes.
4. **Personal archive.** Search, saved messages, global media gallery and an export/backup feature (P1).

## 2. Target users

| Phase | User | Notes |
|---|---|---|
| Months 0–12 (D1) | The founder plus a small trusted circle, via TestFlight | Self-hosted Synapse (D4); one push gateway |
| Year 2+ (D1) | Public App Store users on any homeserver with sliding sync | Needs the legal review (D38), onboarding and support for many homeservers |

Primary persona: a technical power user who runs their own homeserver and personal bots, is in DMs,
small groups and a few busy rooms, and is frustrated by badges that are wrong.

## 3. Core use cases

1. Glance at the icon badge and trust it: it counts rooms that need me (D5).
2. Read a conversation on my Mac; my iPhone's badge and notifications clear without me opening Halo (D11).
3. Get an encrypted DM notification with the sender and preview, not "New message" (D10).
4. Reply to, react to, edit and delete messages in DMs and groups.
5. Send a sticker from my own pack in two taps, and see it rendered correctly in FluffyChat/Element.
6. See my todo bot's list as a native checklist and tick an item off (P1, D20–D23).
7. Find a message from last month in an encrypted room (P1).
8. Save a message for later and come back to the original (P1, D31, D33).
9. Browse every photo shared with me across rooms (P1, D34).
10. Export a room's history to my own storage (P1, D32).

## 4. Feature requirements

### 4.1 P0 — MVP (daily-driver switch)

| Area | Requirement |
|---|---|
| Auth | OIDC (Matrix Authentication Service) and legacy password login; logout; session restore (D15) |
| E2EE | Cross-signing bootstrap; verify by QR code or emoji with another device; recovery key; key backup restore; show UTD (unable to decrypt) messages with a clear reason |
| Devices | List and sign out other sessions (or link to the MAS account page when OIDC is used) |
| Room list | Sliding-sync room list; DMs, groups and invites; unread, mention and attention indicators driven by the unread engine; filters (unread, DMs, favourites); accept and decline invites |
| Timeline | Text (with formatting), notices, emotes, images, video, files, audio (playback), stickers, state events (summarised), redacted placeholders, UTD placeholders; read-marker line; jump to unread; date separators |
| Composer | Text with Markdown; mentions (`m.mentions`); replies; edits; delete (redact); reactions; local echo with send state; retry for failed sends |
| Media | Display all incoming media (encrypted download, cache); send images from the photo picker (D16) |
| Threads | Not supported: thread messages shown inline as replies (D17) |
| Stickers v1 | Panel with packs from MSC2545 (user and room packs); favourites; recents; search by shortcode/body; preview on long press; send `m.sticker`; render incoming `m.sticker`; animated WebP/GIF/APNG (D12, D13); create a personal pack from photos |
| Typing and receipts | Send and show typing; show read receipts (avatars); public `m.read` by default with a private toggle (D7) |
| Unread and notifications | See `05-Unread-Notification-Design.md`; acceptance criteria in §6 |
| Push | APNs via self-hosted Sygnal, `event_id_only` payloads; NSE decrypts and builds a rich notification; notification filtering when Apple grants the entitlement (D10) |
| Room info | Name, avatar, topic, members (list, profile), leave room, notification mode per room (all / mentions / mute), mark as unread (`m.marked_unread`) |
| Bot rendering (generic) | Better HTML-subset rendering for all messages, plus a "view source" option (D29) |
| Calls | Show call events as timeline items only (D43) |
| Settings | Account, notifications, privacy (receipt mode), about and licences (generated acknowledgements, D39) |

**Also-needed essentials** that the original list missed (added in the interview):
UTD handling, invites, `m.marked_unread`, per-room notification modes, a send queue with offline retries,
a "view source" debug view, the acknowledgements screen, a diagnostic export (unread auditor, D35), and
the app's sign-out/key-loss warnings (recovery key not saved).

### 4.2 P1 — after the MVP (order per D28)

1. **Unread hardening:** auditor dashboards, replay tooling, threads with per-thread receipts.
2. **Stickers v2:** room pack management, pack sharing (send a pack link), importing from image sets, pack editing.
3. **Bot renderer, template layer** (D20–D23): todo list and task-confirmation cards, reminder cards; 👍-reaction checkbox protocol with pending state.
4. **Search** (D30): local index of decrypted messages; evaluate upstream `search_service` first.
5. **Saved messages** (D31, D33): copy into a private "Saved" room with origin metadata and a jump back to the original.
6. **Global media gallery** (D34).
7. **Export archive** (D32).
8. **Activity tab** (D26): read-only collection of parsed bot cards.
9. Threads UI; sending video and files; drafts; link previews.

### 4.3 P2

- Calls via MatrixRTC / Element Call widget, with CallKit (D43).
- Optional on-device AI (Foundation Models, iOS 26), always kept separate from the bot (D18).
- Tables and charts in bot messages, only after a separately approved, backward-compatible bot change (D21).
- Public-release work: onboarding for other homeservers, App Store compliance, localisation.

## 5. Product differentiation — and features challenged

| Keep (high value) | Why |
|---|---|
| Correct unread state | The reason for switching apps; it can be measured (auditor) |
| Sticker panel | The original motivation; visible delight; works with other clients |
| Native bot cards | Unique, and costs nothing on the bot side |
| Local search plus saved messages | Element X is weak here for E2EE rooms |

| Deferred or cut | Reason |
|---|---|
| Tables/charts inferred from free text | Unreliable; violates "render only on reliable recognition" (D21) |
| Lottie/TGS stickers | Other Matrix clients can't render them (D13) |
| In-app LLM | The bot already does this; would duplicate a privacy surface (D18) |
| Continuous automatic backup | Background work, storage and retention cost; on-demand export first (D32) |
| Activity tab in the MVP | Would be a second store of bot data before the parsers are proven (D26) |
| Heavy customisation (themes etc.) | Low value compared with correctness work; revisit after P1 |

## 6. Acceptance criteria (MVP)

Unread and notifications (each is an automated scenario test, see doc 05 §8):

- **AC-U1** After a room's latest notifying event has been on screen for 0.5 s in the foreground, the room's
  attention state and the icon badge update within 1 s, and a receipt is sent (or queued while offline).
- **AC-U2** Reading on another device clears the room's attention state within 5 s while Halo is in the
  foreground, and at the latest on the next foreground or background refresh while it is backgrounded. Delivered
  notifications covered by that receipt are removed.
- **AC-U3** The badge equals the number of rooms with `needs_attention = true`, and is identical
  whether it was computed by the app or by the NSE (same function, same store).
- **AC-U4** After any of: app killed during sync, offline for 24 h, sliding-sync reconnect, a gap in a busy
  room, receipt events arriving out of order, a redacted unread event — the state converges to the server's
  read position with no manual action.
- **AC-U5** The badge never goes down because of a gap or uncertainty (no false "all read") and never stays above zero once every room has been read elsewhere (server `notification_count == 0`, no `marked_unread`).
- **AC-U6** The on-device auditor reports zero unexplained disagreements over 7 days of daily use before the MVP ships.

Messaging:

- **AC-M1** Sending text, a reply, an edit, a reaction or a delete appears immediately as a local echo; it survives an app kill and is sent on relaunch.
- **AC-M2** An encrypted message from a verified device decrypts and appears in the NSE notification within APNs' time budget.
- **AC-M3** A sticker sent from Halo displays as a sticker in Element Web and FluffyChat; stickers from those clients render in Halo.
- **AC-M4** The room list for an account with 300 rooms loads from cache in under 1 s on a cold start.

Licensing:

- **AC-L1** The CI licence gate passes; the acknowledgements screen lists every distributed dependency.
- **AC-L2** No source file in the repository came from Element X; the policy is in CONTRIBUTING.md (D37).
