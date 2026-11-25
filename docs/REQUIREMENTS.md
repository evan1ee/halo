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
- **AC-U3** The badge is `BadgeCalculator.badge` over all rooms (the unread messages of rooms needing attention, D82), the same in the app, the NSE, the widgets and the list for the same inputs (D118).
- **AC-U4** After app kill during sync, 24 h offline, reconnect, gaps, out-of-order receipts or a redacted unread event, the state converges with no user action.
- **AC-U5** Server counts = 0 where the server can count the room (unencrypted, or encrypted in all-messages mode), not marked unread and no unconfirmed newer event ⇒ no attention (no "phantom unread").
- **AC-U6** A new notifying event the device has seen (sync or push) ⇒ attention until a receipt at or beyond it exists (no "missed unread").
- **AC-U7** Every notification is delivered at most once per event id.
- **AC-U8** (manual soak) 7 days of daily use with zero *unexplained* auditor findings.

## P1 — Core messaging (MVP)

| ID | Requirement | Spec |
|---|---|---|
| R-P1-AUTH | OIDC (MAS) and password login, session restore, logout, soft-logout re-auth | [features/AUTHENTICATION.md](features/AUTHENTICATION.md) |
| R-P1-E2EE | Cross-signing, emoji verification of own devices (QR: Q-VERIFY), recovery key, identity reset, key backup, identity-change notices, UTD display | [features/ENCRYPTION_AND_DEVICES.md](features/ENCRYPTION_AND_DEVICES.md) |
| R-P1-LIST | Room list with attention indicators, filters, invites | [features/ROOM_LIST.md](features/ROOM_LIST.md) |
| R-P1-TL | Timeline: all common event types, pagination, read-marker line, jump to unread | [features/TIMELINE.md](features/TIMELINE.md) |
| R-P1-MSG | Send/receive text, replies, edits, deletes, reactions, polls (create, vote, end), forward, typing, receipts display, offline send queue | [features/MESSAGING.md](features/MESSAGING.md) |
| R-P1-MEDIA | Display and play all incoming media in the app; send photos, videos, files, voice and camera shots | [features/MEDIA_ATTACHMENTS.md](features/MEDIA_ATTACHMENTS.md) |
| R-P1-PUSH | APNs push with E2EE decryption in the NSE, clearing, badge, Reply and Mark as read actions | [features/NOTIFICATIONS.md](features/NOTIFICATIONS.md) |
| R-P1-ROOM | Room details, members, leave, notification mode, mark unread, create DM/room, invite, basic moderation, report, upgraded rooms | [features/ROOM_MANAGEMENT.md](features/ROOM_MANAGEMENT.md) |
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
| R-P2-GALLERY | Global media gallery via a preset non-Matrix room entry in the room list (D34, D83) | [design/NAVIGATION.md](design/NAVIGATION.md), [features/ROOM_LIST.md](features/ROOM_LIST.md), ROADMAP M9 |
| R-P2-EXPORT | Encrypted room export (D32) | ROADMAP M9 |
| R-P2-THREADS | Threads with per-thread receipts | ROADMAP M10 |
| R-P2-CALLS | ~~MatrixRTC calls~~ out of scope (D94) | — |

## UX quality and ship readiness (D84)

Halo must feel like an Apple-native app while keeping its own identity. Findings and evidence: [design/UX_AUDIT.md](design/UX_AUDIT.md);
work: [ROADMAP.md](ROADMAP.md) M21 (M11–M15 built the base).

| ID | Requirement | Spec |
|---|---|---|
| R-UX-NATIVE | System components, iOS 26 materials and Apple interaction patterns first; custom controls need a written reason | [design/DESIGN_SYSTEM.md](design/DESIGN_SYSTEM.md) §1, §11 |
| R-UX-TOKENS | All colour, type, spacing, radius and motion come from `HaloDesignSystem` tokens | DESIGN_SYSTEM §2–6 |
| R-UX-NAV | App shell, compose entry point, state restoration and one router for all deep links | [design/NAVIGATION.md](design/NAVIGATION.md) |
| R-UX-ONBOARD | First run: welcome, homeserver help, device verification, notification priming | [design/SCREEN_SPECIFICATIONS.md](design/SCREEN_SPECIFICATIONS.md) S1, S2, S14 |
| R-UX-STATES | Loading, empty and error states on every screen; human error copy | DESIGN_SYSTEM §8, §12 |
| R-UX-A11Y | VoiceOver, Dynamic Type AX5, Voice Control and the system accessibility settings | NFR-6, DESIGN_SYSTEM §9 |
| R-UX-L10N | Localisation-ready strings, plurals and formats | NFR-9 |
| R-SHIP | Privacy manifest, App Store metadata, legal review, beta feedback path, performance budgets | ROADMAP "Ship-ready definition" |

### Acceptance criteria
- **AC-UX-1** `scripts/check-design-tokens.sh` passes: no raw `Color.<name>` or `.font(.system(size:))` outside `HaloDesignSystem` (allow-list documented).
- **AC-UX-2** The contrast test passes for every token pair in light, dark and Increase Contrast (≥ 4.5:1 text, ≥ 3:1 large text/UI).
- **AC-UX-3** A new chat can be started from the room list in one tap (compose button); Settings, Stickers, Activity and message search are each reachable from the room list in at most two taps, without a sheet (D85).
- **AC-UX-4** After a kill and relaunch the app reopens the previous navigation path (the open room if still joined).
- **AC-UX-5** (moderated test) Three people with an existing Matrix account each go from first launch to a sent message in ≤ 3 minutes without help.
- **AC-UX-6** Every screen in SCREEN_SPECIFICATIONS shows its loading, empty and error state in a UI test or `#Preview`; lists never show a bare spinner.
- **AC-UX-7** The system notification prompt appears only after the user taps "Turn on" on the priming screen (S14).
- **AC-UX-8** `performAccessibilityAudit()` reports zero issues on the Chats, Timeline, Stickers, Settings and sign-in screens.
- **AC-UX-9** (manual) The golden path (sign in → open room → send → react → leave) works with VoiceOver only and at AX5 text size.
- **AC-UX-10** Every user-facing string is in a String Catalog; a pseudo-language run shows no clipped or hard-coded text.
- **AC-UX-11** NFR-1 and NFR-2 measured on an iPhone 15-class device with XCTest metrics and recorded in TEST_STRATEGY.
- **AC-UX-12** The archive's privacy report lists the app's and NSE's privacy manifests, and App Store Connect accepts the build without warnings.

## Release quality (1.0)

Production release requirements beyond features ([ROADMAP.md](ROADMAP.md) M17–M22, "Ship-ready definition"). Implementing a feature without these isn't done.

### Acceptance criteria — reliability
- **AC-REL-1** Icon, widgets, room list and open room agree after every row of the device matrix (foreground, suspended, terminated, rebooted and locked, airplane mode, clock change, second device). Widgets may lag only by iOS's reload budget and say when they're old.
- **AC-REL-2** Every push that arrives ends in exactly one correct notification or none; no stale notification survives 5 s of foreground.
- **AC-REL-3** An own message is never lost, duplicated or reordered across kill, reconnect, rate limit and token expiry; its shown state is never ahead of the server's.
- **AC-REL-4** Every user action that can fail says so within 10 s or shows that it is still trying; none fails silently; none runs twice from a double tap.
- **AC-REL-5** A damaged, locked or unreadable store never loops or loses the account silently: it recovers or offers a reset that says what is lost.
- **AC-REL-6** An OIDC session survives token rotation in the app and the NSE, including when both refresh at once.
- **AC-REL-7** Reply and Mark as read from a notification work with the app terminated, or report the failure.

### Acceptance criteria — security
- **AC-SEC-1** A contact's identity change is visible before the next message to them is sent, and stays visible until handled.
- **AC-SEC-2** A send refused for encryption reasons says which person or device and offers only choices the SDK supports; nothing is sent unencrypted into an encrypted room.
- **AC-SEC-3** A user without their recovery key and other devices can get back to a working, verified account, knowing what is lost.
- **AC-SEC-4** Nothing Halo stores is readable from a device backup or after sign-out; a restored device starts cleanly.
- **AC-SEC-5** A log and diagnostics scan of a full session finds no content, token, key or raw Matrix ID.

### Acceptance criteria — motion and stability of the picture
- **AC-MOT-1** In the audited transitions (ROADMAP M19-9) there is no frame with a blank, wrong or placeholder state when the content is already on the device, and no row moves except by the user's action or an insertion at the edge.
- **AC-MOT-2** All motion uses `HaloMotion`; with Reduce Motion nothing slides, scales or springs; no interaction waits for an animation.

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
| NFR-9 | Localisation-ready: every user-facing string in a String Catalog; plurals, dates and numbers locale-aware; layouts survive +100 % string length and right-to-left |
| NFR-10 | App Store compliance: privacy manifests for every target, no tracking, privacy labels match [security/PRIVACY.md](security/PRIVACY.md); report and ignore available where others' content is shown |
| NFR-11 | Opening a cached room: newest message drawn p95 ≤ 250 ms after the tap, no spinner, no jump **[ASSUMPTION: baseline in M17-5]** |
| NFR-12 | Memory: ≤ 200 MB in a media timeline, ≤ 300 MB peak in the gallery and viewer, ≤ 10 % growth over 50 room open/close cycles **[ASSUMPTION: baseline in M17-5]** |
| NFR-13 | Main thread: no hang ≥ 250 ms in the scripted session; no image decoding, database or JSON work on it |
| NFR-14 | Sync at 1,000 rooms: first sync to a usable list ≤ 60 s on Wi-Fi, catch-up after 24 h ≤ 10 s, no memory kill **[ASSUMPTION: V-SCALE-1; decides G-SCALE]** |
| NFR-15 | Energy: idle in the foreground ≤ 4 % battery per hour, no background work beyond iOS's grants **[ASSUMPTION: baseline in M17-4]** |
