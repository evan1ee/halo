# ADR-0021: App icon badge shows total unread message count across rooms needing attention

- **Status:** Accepted (founder decision 2026-11-21) · **Date:** 2026-11-21 · **Decision IDs:** D82 (supersedes D5; preserves D9 and D65)

## Context
Under **D5**, the iOS app icon badge showed the number of rooms needing attention (`states.filter(\.attention).count`), so 10 unread messages in one room showed `10` on the room row and `1` on the app icon. During physical-device verification on 2026-11-21, the founder decided that the app icon badge should reflect the number of unread messages rather than the number of rooms.

## Problem
How should the iOS app icon badge number be derived from `ReadStatePolicy` in both the foreground app and the background Notification Service Extension (NSE), while preserving **D9** (one pure recomputation function, never blind increments) and **D65 / ADR-0015** (push payloads never control the badge)?

## Considered alternatives
1. **Keep D5 (room count):** `10` unread messages in one room displays `1` on the icon; rejected by founder as unintuitive compared to the room list badge.
2. **Sum `RoomReadState.badgeCount` across rooms with `attention == true` (chosen):** each attention room contributes its unread message/mention count (≥ 1 for invites or marked-unread rooms); `AttentionCache` stores per-room counts + write timestamp so the NSE recomputes from GRDB `notification_record` without raw increments.
3. **Copy server `counts.unread` from push payloads:** violates D65/ADR-0015 and overcounts encrypted non-messages (R-01).

## Decision
**D82 (supersedes D5):** `BadgeCalculator.badge(_ states: [RoomReadState]) -> Int` sums `RoomReadState.badgeCount` across all rooms where `state.attention == true`:

| Room state | `badgeCount` |
|---|---|
| `attention == false` (read, muted without mark-unread, mentions-only without mentions) | `0` |
| Invited (`membership == .invited`, E0) | `1` |
| Joined, `allMessages` mode, `attention == true` | `max(notify, highlight, 1)` |
| Joined, `mentionsAndKeywords` mode, `attention == true` | `max(highlight, 1)` |
| Joined, `mute` mode, `isMarkedUnread == true` | `1` |

## Rationale
Summing `badgeCount` across attention rooms matches user expectations (10 unread messages in a room → `10` on the icon) while respecting room notification modes (muted rooms and non-mention chatter in mentions-only rooms still contribute `0`). Storing `[RoomID: Int]` + `updatedAt` in `AttentionCache` lets the NSE derive its background badge from `base[room] + ReadStatePolicy.evaluate(unconfirmedRecordsSinceWrite).badgeCount` over PK-deduplicated GRDB `notification_record` rows, preserving D9 and D65.

## Trade-offs
- In encrypted rooms where `confidence == .approximate` (SDK counts lag behind a gap), the icon badge reflects the SDK's known unread count (≥ 1) until the next sync catches up, rather than a constant `1` per room.
- `AttentionCache` migrates from `attentionRooms.v1` (`[String]`) to `attentionCounts.v2` (`[String: Int]` + timestamp), falling back cleanly to `1` per legacy room on first launch after upgrade.

## Consequences
- `RoomReadState` gains `badgeCount: Int`.
- `BadgePort` and `AttentionCache` carry `[RoomID: Int]` instead of `Set<RoomID>`.
- `ReadStateCoordinator` and `NotificationProcessor` both compute the badge via `ReadStatePolicy` / `BadgeCalculator` and agree with the room list's unread counts.
