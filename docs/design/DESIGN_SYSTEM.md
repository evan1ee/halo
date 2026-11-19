# Design System

Module: `HaloDesignSystem`. Halo has **its own visual identity** — it isn't derived from Element X's colours,
icon set, layouts or component shapes (D37). Values below are the starting tokens; they change only via this document.

## 1. Principles
1. **Calm**: neutral surfaces, colour reserved for meaning (attention, mentions, errors).
2. **Honest states**: pending, failed and uncertain states always look different from confirmed ones.
3. **Native**: SF Pro, SF Symbols, system materials, standard gestures; no custom fonts in the MVP.
4. **Accessible first**: Dynamic Type, VoiceOver, contrast ≥ WCAG AA (4.5:1 text, 3:1 large text/UI).

## 2. Colour tokens
Defined as asset-catalogue colours with light/dark variants; code uses semantic names only.

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg.primary` | #FFFFFF | #0E0F12 | Screens |
| `bg.secondary` | #F4F5F7 | #17191E | Grouped backgrounds, composer |
| `bg.elevated` | #FFFFFF | #1E2128 | Sheets, panels |
| `text.primary` | #111317 | #F2F3F5 | Body |
| `text.secondary` | #5B616E | #A3A9B6 | Meta, timestamps |
| `accent` | #5B4BDB (Halo indigo) | #8C7FF0 | Primary actions, own bubbles, links |
| `onAccent` | #FFFFFF | #111317 | Text/glyphs on an `accent` fill (6.04:1 / 5.68:1) |
| `attention` | #C2410C (burnt orange) | #FF7A33 | Unread badge fill |
| `onAttention` | #FFFFFF | #111317 | Count on the unread badge (5.18:1 / 7.16:1) |
| `mention` | #D6336C | #F06595 | Mention badge fill `@` |
| `onMention` | #FFFFFF | #111317 | Count on the mention badge (4.62:1 / 6.20:1) |
| `success` | #237A35 | #51CF66 | Bot completed, sent |
| `warning` | #8A6100 (amber) | #FCC419 | Pending, unverified — a yellow-amber hue, kept clearly apart from `attention` so "pending" never reads as "unread" |
| `danger` | #C92A2A | #FF6B6B | Failed, destructive |
| `bubble.own` | accent at 14 % on bg | accent at 28 % | Own messages |
| `bubble.other` | `bg.secondary` | `bg.secondary` | Others' messages |

A unit test over the asset catalogue (M0) checks every foreground/background pair used: `text.*`, `accent`, `success`, `warning`, `danger`
on `bg.primary`, `bg.secondary` and `bg.elevated` (≥ 4.5:1), and each `on*` token on its fill (≥ 4.5:1), in light and dark. The values
above were chosen to pass it (ratios computed with the WCAG 2.x formula; badge pairs shown in the table).

## 3. Typography
Text styles map to Dynamic Type: `title` (.title2 semibold), `headline` (.headline), `body` (.body), `bodyEmphasis` (.body semibold),
`meta` (.footnote), `caption` (.caption1), `code` (.body monospaced). No fixed font sizes anywhere.

## 4. Spacing, radius, elevation
- Spacing scale (pt): `xxs 2 · xs 4 · s 8 · m 12 · l 16 · xl 24 · xxl 32`.
- Radius: `small 6` (chips), `medium 12` (cards), `bubble 18` (message bubbles, continuous corners), `sheet 24`.
- Elevation: system materials (`.regularMaterial`) for panels; no custom shadows except the sticker preview (y 8, blur 24, 20 %).

## 5. Iconography
SF Symbols only (MVP). Halo-specific glyphs (app icon, empty-state illustrations) are original artwork commissioned or drawn for Halo — never taken from Element.

## 6. Motion
- Standard spring: `.spring(response: 0.35, dampingFraction: 0.85)`; sticker panel: `.spring(response: 0.3, dampingFraction: 0.9)`.
- Badges change with a fade + scale (0.15 s). Bubbles appear with a 0.2 s fade + 4 pt rise.
- **Reduce Motion**: replace movement with cross-fades; stickers show their first frame.

## 7. Components (MVP)

| Component | Variants / states |
|---|---|
| `Avatar` | sizes 24/32/40/56/96; image / initials (deterministic colour from id hash); presence dot (P2) |
| `RoomRow` | indicator `.none/.dot/.count/.mentions`, bold (hasUnread), muted, favourite, invite |
| `UnreadIndicator` | dot · count (1–99, "99+") · mention (`@n`) · approximate (dot with a ring) |
| `MessageBubble` | own/other · grouped first/middle/last · states sending/sent/failed · edited · reply header |
| `ReactionChip` | count, own-selected, pending |
| `TimelineSeparator` | date · read marker ("New") |
| `MediaTile` | image/video/file/audio; loading/failed/blurhash |
| `StickerView` | static/animated, paused, unavailable |
| `BotCard` | checklist, task, reminder, compact status; "Bot card" affordance; row states open/pending/completed/failed/unavailable |
| `Banner` | offline, unverified device, soft logout, push disabled |
| `EmptyState` | icon, title, message, optional action |
| `ErrorState` | inline (tile/row) and full-screen with retry |
| `LoadingState` | skeleton rows/bubbles (no spinners for lists) |

## 8. Loading, empty and error states
Every screen spec ([SCREEN_SPECIFICATIONS.md](SCREEN_SPECIFICATIONS.md)) defines all three. Rules: show cached content first; skeletons only when nothing is cached;
errors inline where the data is; never a blank screen.

## 9. Accessibility checklist (per component)
VoiceOver label + value + hint (e.g. RoomRow: "Alice, 3 unread messages, last message 'see you', 10:42"); minimum hit target 44×44;
Dynamic Type up to AX5 without truncating essential info; colour is never the only signal (badges have text/shape); Bot-card states have text labels.

## 10. Themes
System (default), Light, Dark. P2: accent colour choices.
