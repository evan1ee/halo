# Screen Specifications

Each screen: responsibility · content · actions · loading / empty / error states · accessibility notes.
Behaviour details are in the feature specs; this document covers layout and states only.

## S1 Onboarding / Login
- **Responsibility:** server entry and login method choice (AUTHENTICATION).
- **Content:** Halo logo (original artwork, Q-BRAND), one-line value statement, server field (prefilled with the last-used server) with an inline "What's a homeserver?" explanation and the suggestion of Q-ONBOARD-SERVER, "Continue".
- **States:** loading (discovering) → method buttons; error inline under the field ("This server doesn't offer a sign-in Halo supports.").
- **A11y:** the field labelled "Homeserver or Matrix ID".

## S2 Verify this device
- Options as large cells: "Use another device", "Enter recovery key", "Skip for now" (with a consequence note).
- States: waiting for the other device (emoji grid when ready), success check, failure with retry.

## S3 Room list (the app's root, D85)
- **Header:** account avatar top-leading (→ Settings; dot when this device needs verification), large title "Chats", sync indicator (small, only when not up to date), more menu (`ellipsis.circle`: filters, Stickers, Activity) and compose (`square.and.pencil`, opens New chat) top-trailing, search field (room names while typing, plus a "Messages" results section, D85). Pull to refresh runs a sync round trip.
- **Filters:** in the more menu — All · Unread · People · Rooms · Favourites · Invites; the active filter shows under the title.
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

## S6 Sticker library (pushed from the more menu or Settings → Stickers)
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

## S14 Notifications priming (first run, after S2)
- **Responsibility:** explain why Halo needs notifications before the one-time system prompt (AC-UX-7, D84).
- **Content:** illustration, "Know when it matters" title, two bullet benefits (messages and mentions; the badge is always right), "Turn on notifications" (shows the system prompt), "Not now".
- **States:** if already authorised or denied, the screen is skipped; denied later → Settings → Notifications shows the "Open iOS Settings" row (SETTINGS).
- **A11y:** the illustration is decorative (hidden); buttons ≥ 44 pt.

## S15 First-run checklist
- **Responsibility:** the short path from sign-in to a ready app: verify this device (S2) → notifications (S14) → done ("You're all set").
- **Content:** three rows with status (done / skipped / to do); each can be skipped; reachable again from Settings while anything is left.
- **States:** completes automatically when each step is done elsewhere (e.g. verification on another device).

## State matrix (AC-UX-6, ROADMAP M21-1)

Every screen in S1–S15 (and its supporting views) uses the shared `HaloDesignSystem` state components (`LoadingState`, `EmptyState`, `ErrorState`, `HaloBanner`) so lists, grids, and detail screens never show a bare spinner and every failure gives a plain-English recovery path. Each cell records its built behaviour and the `#Preview` or automated test verifying it (`—` means not applicable to that screen).

| Screen | Loading | Empty | Error | Offline | No-permission | Recovering |
|---|---|---|---|---|---|---|
| **S1 Onboarding / Sign in** (`SignInView`) | `.launching`/`.busy` form progress (`AuthViewModelTests`) | Server prompt + homeserver help (`AuthViewModelTests`) | Inline error under form (`AuthViewModelTests`) | Offline copy via `AuthMessages` (`AuthViewModelTests`) | — | `.restoreFailed` retry & damaged-store reset disclosure (`AuthViewModelTests`) |
| **S2 Verify this device** (`RecoveryView`) | Waiting / starting SAS progress (`RecoveryViewModelResetTests`) | — | `ErrorState` with Retry + inline `ErrorState` (`RecoveryViewModelResetTests`) | Offline failure via `ErrorState` (`RecoveryViewModelResetTests`) | — | SAS emoji/decimal confirm → verified (`RecoveryViewModelResetTests`) |
| **S3 Room list** (`RoomListView`, `NewChatView`, `MessageSearchResultsSection`) | `LoadingState(.roomList())`, `LoadingState(.rows(count: 3))` (`LoadingState` `#Preview`, `StateComponentsTests`) | `EmptyState` per filter; empty search (`EmptyState` `#Preview`, `RoomListViewModelTests`, `MessageSearchViewModelTests`, `NewChatViewModelTests`) | Full-screen `ErrorState` with Retry; inline `ErrorState` in New Chat & Search; `HaloBanner(.danger)` (`ErrorState` `#Preview`, `RoomListViewModelTests`, `MessageSearchViewModelTests`) | `syncNotice` offline bar; Search offline coverage notice (`RoomListViewModelTests`, `MessageSearchViewModelTests`) | — | `syncNotice` reconnecting + `RecoveryBanner` (`RoomListViewModelTests`) |
| **S4 Timeline** (`TimelineView`, `PinnedMessagesSheet`, `EditHistoryView`, `RoomSearchBar`) | `DelayedLoadingState` (`LoadingState(.timeline())` after 1 s, preserving D126 0-flash); `LoadingState(.rows(count: 3))` in Edit History (`StateComponentsTests`, `TimelineViewModelTests`) | `EmptyState` ("No messages yet", "No pinned messages", "No edits yet"); in-room search empty (`TimelineViewModelTests`, `PinMessageTests`, `RoomSearchViewModelTests`) | Full-screen `ErrorState` with Retry; inline `ErrorState` for pagination failure; `ErrorState` in Edit History (`ErrorState` `#Preview`, `TimelineViewModelTests`, `MessageDeliveryTests`) | Offline send queue honest pending/failed rows; in-room search offline notice (`MessageDeliveryTests`, `RoomSearchViewModelTests`) | Camera/mic denied status sheet + Open Settings (`CameraCaptureTests`, `AudioPlaybackControllerTests`) | `RoomLifecycleBanner`, `IdentityNoticeBanner`, UTD tiles (`RoomLifecycleViewModelTests`, `TimelineViewModelTests`) |
| **S5 Sticker & GIF panel** (`StickerPanelView`, `KlipyPanelView`) | `LoadingState(.grid(...))` (`LoadingState` `#Preview`, `StateComponentsTests`) | `EmptyState` ("No sticker packs yet" + CTA); `ContentUnavailableView.search` (`StickerPanelViewModelTests`, `KlipyPanelModelTests`) | Full-screen `ErrorState` with Retry; `HaloBanner(.danger)` for send errors (`StickerPanelViewModelTests`, `KlipyPanelModelTests`, `StateComponentsTests`) | Offline load failure with Retry (`StickerPanelViewModelTests`, `KlipyPanelModelTests`) | — | Unavailable packs removal notice + incomplete-pack notice (`StickerPanelViewModelTests`) |
| **S6 Sticker library** (`StickerLibraryView`, `AddToStickerPackSheet`) | `LoadingState(.rows(count: 4))` / `.rows(count: 3)` (`StateComponentsTests`, `StickerLibraryViewModelTests`) | `EmptyState` ("No sticker packs yet" + CTA; "Pack unavailable") (`StickerLibraryViewModelTests`) | Full-screen `ErrorState` with Retry (`loadFailed`); `HaloBanner(.danger)` (`StickerLibraryViewModelTests.surfacesLoadFailureAndRecovers`) | Offline failure with Retry (`StickerLibraryViewModelTests.surfacesLoadFailureAndRecovers`) | System `PhotosPicker` (no library permission required) | Unavailable packs removal row (`StickerLibraryViewModelTests`) |
| **S7 Room details & lifecycle** (`RoomDetailsView`, `RoomMediaGalleryView`, `RoomPreviewSheet`, `InactiveRoomsView`) | `LoadingState(.detail(rows: 5))`, `LoadingState(.rows(count: 5))`, `LoadingState()` (`StateComponentsTests`, `RoomDetailsViewModelTests`, `RoomLifecycleViewModelTests`) | `EmptyState` ("No media yet", inactive rooms empty) (`RoomDetailsViewModelTests`, `RoomLifecycleViewModelTests`) | Full-screen & inline `ErrorState` with Retry (`RoomDetailsViewModelTests`, `RoomModerationViewModelTests`, `RoomLifecycleViewModelTests`) | Offline error with Retry; cached details remain visible (`RoomDetailsViewModelTests`, `RoomModerationViewModelTests`) | System `PhotosPicker` | Upgraded-room successor section & banner (`RoomLifecycleViewModelTests`) |
| **S8 Profile** (`UserProfileView`, `ProfileSettingsView`) | `LoadingState(.detail(rows: 3))` (`StateComponentsTests`, `UserProfileViewModelTests`) | "No display name" fallback; empty ignored users (`UserProfileViewModelTests`, `ProfileSettingsTests`) | Full-screen `ErrorState` with Retry; inline `ErrorState` for action errors (`UserProfileViewModelTests.failedLoadRecoversOnRetry`) | Offline error with Retry (`UserProfileViewModelTests.failedLoadRecoversOnRetry`) | System `PhotosPicker` | — |
| **S9 Media viewer & Global Gallery** (`GlobalMediaGalleryView`, `PagedPhotoViewer`, `VideoPlayerSheet`) | `LoadingState(.grid(columns: 3, count: 9))` / `.rows(count: 6)`; dark-backdrop viewer loader (`StateComponentsTests`, `GlobalMediaGalleryViewModelTests`) | `EmptyState` per media filter (`GlobalMediaGalleryViewModelTests`) | Full-screen & inline `ErrorState` with Retry; photo-load failure with Retry; unplayable video Share fallback (`GlobalMediaGalleryViewModelTests`, `VideoPlaybackAndSendTests`) | Offline error with Retry (`GlobalMediaGalleryViewModelTests`) | Save to Photos denied toast ("Allow Photos access in Settings") (`VideoPlayerSheet`, `PagedPhotoViewer`) | — |
| **S10 Settings** (`SettingsView`, `DevicesSettingsView`, `StickerPackSettingsView`, `StorageSettingsSection`) | `LoadingState(.rows(count: 3))` in Sessions & Sticker Packs; inline calculating state in Storage (`DevicesSettingsTests`, `StickerPackSettingsTests`, `StorageSettingsTests`) | `EmptyState` ("No sessions", "No packs added"); search empty in Acknowledgements (`DevicesSettingsTests`, `StickerPackSettingsTests`, `AcknowledgementsTests`) | Full-screen & inline `ErrorState` with Retry in Sessions; inline `ErrorState` in Sticker Packs & Storage (`DevicesSettingsTests`, `StickerPackSettingsTests`, `StorageSettingsTests`) | Offline errors retain current values (`NotificationDefaultsTests`, `DevicesSettingsTests`, `StorageSettingsTests`) | Notifications denied → "Open iOS Settings" row (`SettingsView`) | Auditor badge, Diagnostics "Reconcile now", "Verify this device", "Lost your recovery key?" (`SettingsView`) |
| **S11 Bot cards** (`BotCardView` inside S4) | Pending tick spinner ("Waiting for bot…") (`TimelineChildModelsTests`) | — | Failed row (`⚠` + Retry) (`TimelineChildModelsTests`) | Queued / failed reaction state (`TimelineChildModelsTests`) | Unavailable row ("Not available") | Reconciles on next bot message (`TimelineChildModelsTests`) |
| **S12 Activity** (`BotActivityView`) | `LoadingState(.roomList(count: 5))` (`BotActivityViewModelTests`) | `EmptyState` ("Nothing yet") (`BotActivityViewModelTests`) | Full-screen `ErrorState` with Retry (`BotActivityViewModelTests`) | Local device tasks shown offline (`BotActivityViewModelTests`) | — | "Rebuild list" destructive confirmation (`BotActivityViewModelTests`) |
| **S13 Re-auth** (`SignInView` `.softLoggedOut`) | `.busy` (`AuthViewModelTests`) | — | Inline error message (`AuthViewModelTests`) | Offline error message (`AuthViewModelTests`) | — | "Your session expired. Sign in again to continue." (`AuthViewModelTests`) |
| **S14 Notifications priming** (`NotificationPrimingView`) | "Requesting…" disabled CTA (`NotificationPrimingView`) | — | System prompt error handled cleanly | Works offline (skippable) | Skipped if denied; Settings links to iOS Settings | — |
| **S15 First-run checklist** (`FirstRunChecklistView`) | Live reactive step status | — | Delegates to S2 / S14 | Skippable offline | Notifications step links to S14 / Settings | Auto-completes when verified elsewhere |

