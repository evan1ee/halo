# Requirements

Requirement IDs are stable; feature specs refine them. Priority per D45:
**P0** read-state correctness · **P1** core messaging (MVP) · **MVP+** stickers v1 (in the MVP) · **P2** later.

## P0 — Read-state and notification correctness

Full design: [matrix/UNREAD_STATE.md](matrix/UNREAD_STATE.md). Must be prevented:

| ID | Failure that must not happen |
|---|---|
| R-P0-1 | A room shows unread/attention although every message in it has been read (on any device) |
| R-P0-2 | A new notifying message arrives but the room doesn't show attention |
| R-P0-3 | Room-list indicator and timeline disagree (e.g. list says unread, the timeline shows no unread line and nothing new) |
| R-P0-4 | Receipts, server notification counts and the badge stay inconsistent after sync settles |
| R-P0-5 | Unread state comes back after sync, app restart or a background/foreground transition |
| R-P0-6 | Duplicate notifications, or stale delivered notifications that stay after the room was read |
| R-P0-7 | The badge differs between what the NSE set and what the app computes for the same state |

### Acceptance criteria (automated unless noted)
- **AC-U1** Viewing the latest notifying event for ≥ 0.5 s in the foreground clears the room's attention and updates the badge within 1 s; a receipt is sent or queued.
- **AC-U2** Reading on another device clears attention within 5 s while Halo is in the foreground (one sync round trip), and on the next foreground or background refresh otherwise; covered delivered notifications are removed.
- **AC-U3** `badge == count(rooms needing attention)`, the same in the app and NSE paths for the same inputs.
- **AC-U4** After app kill during sync, 24 h offline, reconnect, gaps, out-of-order receipts or a redacted unread event, the state converges with no user action.
- **AC-U5** Server counts = 0, not marked unread and no unconfirmed newer event ⇒ no attention (no "phantom unread").
- **AC-U6** A new notifying event the device has seen (sync or push) ⇒ attention until a receipt at or beyond it exists (no "missed unread").
- **AC-U7** Every notification is delivered at most once per event id.
- **AC-U8** (manual soak) 7 days of daily use with zero *unexplained* auditor findings.

## P1 — Core messaging (MVP)

| ID | Requirement | Spec |
|---|---|---|
| R-P1-AUTH | OIDC (MAS) and password login, session restore, logout, soft-logout re-auth | [features/AUTHENTICATION.md](features/AUTHENTICATION.md) |
| R-P1-E2EE | Cross-signing, QR/emoji verification, recovery key, key backup, UTD display | [features/ENCRYPTION_AND_DEVICES.md](features/ENCRYPTION_AND_DEVICES.md) |
| R-P1-LIST | Room list with attention indicators, filters, invites | [features/ROOM_LIST.md](features/ROOM_LIST.md) |
| R-P1-TL | Timeline: all common event types, pagination, read-marker line, jump to unread | [features/TIMELINE.md](features/TIMELINE.md) |
| R-P1-MSG | Send/receive text, replies, edits, deletes, reactions, typing, receipts display, offline send queue | [features/MESSAGING.md](features/MESSAGING.md) |
| R-P1-MEDIA | Display all incoming media; send images | [features/MEDIA_ATTACHMENTS.md](features/MEDIA_ATTACHMENTS.md) |
| R-P1-PUSH | APNs push with E2EE decryption in the NSE, clearing, badge | [features/NOTIFICATIONS.md](features/NOTIFICATIONS.md) |
| R-P1-ROOM | Room details, members, leave, notification mode, mark unread, create DM/room, invite | [features/ROOM_MANAGEMENT.md](features/ROOM_MANAGEMENT.md) |
| R-P1-PROF | Own profile (name, avatar), other users' profiles, ignore user | [features/USER_PROFILES.md](features/USER_PROFILES.md) |
| R-P1-SET | Settings, privacy (receipt mode), acknowledgements, diagnostics export | [features/SETTINGS.md](features/SETTINGS.md) |
| R-P1-BOTGEN | Generic HTML-subset rendering for all messages + view source (D29) | [features/BOT_MESSAGES.md](features/BOT_MESSAGES.md) §Layer 1 |

## MVP+ — Stickers v1 (in the MVP, D45)

| ID | Requirement | Spec |
|---|---|---|
| R-ST-1 | Sticker panel: packs from `m.image_pack.rooms` + current room's packs; favourites; recents; search; preview | [features/STICKERS.md](features/STICKERS.md) |
| R-ST-2 | Send `m.sticker`; render incoming stickers, animated WebP/GIF/APNG | same |
| R-ST-3 | Create a personal pack from photos (a private pack room) | same |

## P2 — Differentiators after the MVP

| ID | Requirement | Spec |
|---|---|---|
| R-P2-ST | Sticker v2: pack management, sharing, import, room packs | [features/STICKERS.md](features/STICKERS.md) §P2 |
| R-P2-BOT | Bot template cards and reaction interactions (D20–D23) | [features/BOT_MESSAGES.md](features/BOT_MESSAGES.md) |
| R-P2-ACT | Bot Activity tab with task extraction and tracking | [features/BOT_ACTIVITY.md](features/BOT_ACTIVITY.md) |
| R-P2-SEARCH | Local message search (D30) | [ROADMAP.md](ROADMAP.md) M8 |
| R-P2-SAVED | Saved messages room (D31, D33) | ROADMAP M8 |
| R-P2-GALLERY | Global media gallery (D34) | ROADMAP M9 |
| R-P2-EXPORT | Encrypted room export (D32) | ROADMAP M9 |
| R-P2-THREADS | Threads with per-thread receipts | ROADMAP M10 |
| R-P2-CALLS | MatrixRTC calls | ROADMAP (later) |

## Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-1 | Cold start to an interactive room list from cache ≤ 1 s for 300 rooms (iPhone 15 class) **[ASSUMPTION: target to validate in M2]** |
| NFR-2 | Timeline scrolls at 60 fps with mixed media and animated stickers |
| NFR-3 | NSE finishes within its time budget, and memory stays under the system limit (V-NSE-1) |
| NFR-4 | No message content, keys, tokens or full Matrix IDs in logs at default level ([security/SECURITY.md](security/SECURITY.md)) |
| NFR-5 | Works offline: browse cached rooms, compose and queue messages and receipts |
| NFR-6 | Accessibility: Dynamic Type up to AX5, VoiceOver labels on every control, Reduce Motion respected |
| NFR-7 | Data at rest protected by iOS Data Protection; content columns in Halo's DB encrypted |
| NFR-8 | Licence gate passes on every build; acknowledgements complete |
