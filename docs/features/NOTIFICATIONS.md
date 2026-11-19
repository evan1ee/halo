# Feature: Notifications and Badge

> Priority: P0/P1 · Milestone: M1 (spike), M3 (complete) · Modules: NSE target, `NotificationCoordinator`, `ReadStateCoordinator`, HaloPlatform · Requirements: R-P1-PUSH, R-P0-6/7
> Mechanics: [../matrix/PUSH_NOTIFICATIONS.md](../matrix/PUSH_NOTIFICATIONS.md) · State model: [../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md)

## 1. Purpose
Tell the user about what matters — once, with useful content — and remove it when it's been read anywhere.

## 2. User stories
- An encrypted DM shows the sender's name, avatar and text on the lock screen.
- When I read a conversation on my Mac, its notifications disappear from my iPhone.
- The app icon shows how many conversations need me.
- I choose per room: all messages, mentions only, or mute.

## 3. Functional requirements
- FR-1 Permission prompt after onboarding, explaining why; works without permission (no push, badge only when allowed).
- FR-2 Pusher registration and re-registration ([../matrix/PUSH_NOTIFICATIONS.md](../matrix/PUSH_NOTIFICATIONS.md) §2).
- FR-3 NSE pipeline incl. de-duplication and suppression (§3 there).
- FR-4 Communication notifications grouped by room (`threadIdentifier = room_id`).
- FR-5 Notification actions: Reply (text input, sent by the app in the background **[ASSUMPTION V-PUSH-4: the app is launched in the background for the action]**), Mark as read.
- FR-6 Clearing on read anywhere (§5 there).
- FR-7 Badge = rooms needing attention (D5), set via `setBadgeCount` by app and NSE only from `BadgeCalculator`.
- FR-8 Per-room mode in Room details; the global defaults (DMs: all, groups: mentions) in Settings, stored as push rules on the server via the SDK notification settings API (`get_notification_settings`) **[VERIFIED F-FFI-18]**.
- FR-9 Settings show push health: permission, token registered, last push received time.

## 4. Non-functional requirements
NFR-3 (NSE budget); privacy: the default payload alert text contains no content.

## 5. User flows
Push → banner → tap → room opens at the event → reading clears the notification group.

## 6. State transitions
Notification record: `Delivered → Cleared(read) | Cleared(room left) | Expired(30 days)`.

## 7. Data models
`notification_record` ([../data/DATA_MODELS.md](../data/DATA_MODELS.md)), `NotificationMode`.

## 8. API boundaries
`NotificationFetchPort`, `PusherPort`, `SystemNotificationsPort`, `BadgePort`, `ReadStateCoordinator`.

## 9. Error scenarios
Permission denied · token registration failure · NSE timeout · keys missing.

## 10. Edge cases
Two devices of the same user (only this device's pusher) · a push for a room left meanwhile · a push for an edit (`m.replace` → don't notify again) · a redacted event before the push arrives · DND/Focus modes (system handles).

## 11. Acceptance criteria
AC-U2, AC-U3, AC-U6, AC-U7 plus:
- AC-N1 An encrypted DM from a verified user shows sender + text in ≥ 95 % of pushes in a 100-push test (rest: generic text, never a crash).
- AC-N2 An edit never creates a second notification.

## 12. Test requirements
Unit: the NSE pipeline as a pure function with fakes (de-dup, suppress, content building). Integration: S-PUSH-1..4 with a fake push gateway that calls the pipeline directly (no APNs). Manual: device checklist ([../testing/TEST_STRATEGY.md](../testing/TEST_STRATEGY.md) §8).

## 13. Open questions
V-NSE-1/2/3, V-PUSH-1..4.
