# Screen Specifications

Each screen: responsibility · content · actions · loading / empty / error states · accessibility notes.
Behaviour details are in the feature specs; this document covers layout and states only.

## S1 Onboarding / Login
- **Responsibility:** server entry and login method choice (AUTHENTICATION).
- **Content:** Halo logo, one-line value statement, server field (prefilled with the last-used server), "Continue".
- **States:** loading (discovering) → method buttons; error inline under the field ("This server doesn't support Halo (sliding sync missing)").
- **A11y:** the field labelled "Homeserver or Matrix ID".

## S2 Verify this device
- Options as large cells: "Use another device", "Enter recovery key", "Skip for now" (with a consequence note).
- States: waiting for the other device (emoji grid when ready), success check, failure with retry.

## S3 Room list (Chats tab root)
- **Header:** title "Chats", sync indicator (small, only when not up to date), new-chat button, search field (filters by name in the MVP).
- **Filters:** chips row — All · Unread · People · Rooms · Favourites · Invites.
- **Rows:** `RoomRow`; invites section first.
- **Swipe:** leading — Read/Unread; trailing — Mute, Favourite.
- **States:** cached content immediately; skeleton rows only on the first-ever load; empty: "No conversations yet" + "Start a chat"; filter-empty: "Nothing unread 🎉"; error banner on room-list failure.

## S4 Timeline
- **Top bar:** avatar, room name, encryption/verification glyph, tap → room details.
- **Body:** bubbles grouped by sender within 5 min; date separators; read-marker separator "New"; receipts avatars; typing indicator at the bottom.
- **Pills:** "Jump to unread ↑" (when the marker is above the viewport), "↓ N new" when detached.
- **Composer:** text field, attachment (photos), sticker button, send; reply/edit banner above the field.
- **States:** loading older (top spinner row), pagination error row with retry, empty room ("Say hello 👋"), UTD tiles.

## S5 Sticker panel (sheet from the composer, medium detent)
- Search field; section bar (Favourites ★, Recent 🕘, pack avatars); grid 4 columns (5 on Max phones); "+" for a new pack.
- **States:** loading packs (skeleton grid), no packs ("Create your first pack" CTA), pack unavailable rows, search empty.
- Long-press: floating preview card with animation, "Send" / "Favourite".

## S6 Sticker library (Stickers tab)
- My packs (personal), Enabled packs (from rooms), Favourites. Pack detail: grid, rename, edit shortcodes, delete (personal only), privacy note ("Sticker packs are not end-to-end encrypted").
- New pack flow: name → photo picker → editor (shortcode per image, grammar validation inline) → upload progress (n/m) → done.

## S7 Room details
- Header (avatar, name, topic), encryption state; rows: Notifications (mode), Members (count), Media (P2), Favourite toggle, Mark unread, Leave (destructive).

## S8 Members / Profile
- Searchable member list with role badges. Profile: avatar, name, user ID, actions (Message, Ignore, Verify P2).

## S9 Media viewer
- Full-screen, swipe between items, zoom, share/save; video controls; caption overlay.

## S10 Settings
Grouped list per [../features/SETTINGS.md](../features/SETTINGS.md) §3. Diagnostics screen shows: auditor status (green/amber with count), last reconcile time, "Reconcile now", "Export diagnostics".

## S11 Bot cards (inside S4)
- Checklist card: title, rows (checkbox, `#id`, text, priority chip, owner), footer "From @bot · Show original".
- Row states: open ☐, pending (spinner in the box, "Waiting for bot…"), completed ☑ (strike-through), failed (⚠ + Retry), unavailable (greyed box, "Not available").

## S12 Activity (P2)
- Segmented control: Open · Reminders · Completed; filter menu (room, bot); rows: task title, room name, "as of 10:42", status; header note "From messages on this device".

## S13 Re-auth sheet
- "Your session expired — sign in again to continue. Your messages stay on this device." + login method buttons.
