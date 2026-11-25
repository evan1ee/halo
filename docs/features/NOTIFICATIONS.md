# Feature: Notifications and Badge

> Priority: P0/P1 · Milestone: M1 (spike), M3 (complete) · Modules: NSE target, `NotificationCoordinator`, `ReadStateCoordinator`, HaloPlatform · Requirements: R-P1-PUSH, R-P0-6/7
> Mechanics: [../matrix/PUSH_NOTIFICATIONS.md](../matrix/PUSH_NOTIFICATIONS.md) · State model: [../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md)

## 1. Purpose
Tell the user about what matters — once, with useful content — and remove it when it's been read anywhere.

## 2. User stories
- An encrypted DM shows the sender's name, avatar and text on the lock screen.
- When I read a conversation on my Mac, its notifications disappear from my iPhone.
- The app icon shows how many unread messages need me (D82).
- I choose per room: all messages, mentions only, or mute.

## 3. Functional requirements
- FR-1 Permission prompt after onboarding, explaining why; works without permission (no push, badge only when allowed).
- FR-2 Pusher registration and re-registration ([../matrix/PUSH_NOTIFICATIONS.md](../matrix/PUSH_NOTIFICATIONS.md) §2).
- FR-3 NSE pipeline incl. de-duplication and suppression (§3 there).
- FR-4 Communication notifications grouped by room (`threadIdentifier = room_id`).
- FR-5 Notification actions: Reply (text input, sent by the app in the background **[ASSUMPTION V-PUSH-4: the app is launched in the background for the action]**), Mark as read. *Not built: no notification category is registered* (ROADMAP M18-7).
- FR-6 Clearing on read anywhere (§5 there).
- FR-7 Badge = unread messages of rooms needing attention (D82), set via `setBadgeCount` by app and NSE only from `BadgeCalculator`; one count for icon, widgets and list (D118).
- FR-8 Per-room mode in Room details; the global defaults (DMs: all, groups: mentions) in Settings, stored as push rules on the server via the SDK notification settings API (`get_notification_settings`) **[VERIFIED F-FFI-18]**. Trade-off of the group default: encrypted groups in mentions mode get no server cross-check for unread state (rule E2x, [../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md) §9).
- FR-9 Settings show push health: permission, token registered, last push received time.
- FR-10 A message notification offers **Reply** (typed in the notification) and **Mark as read**; neither opens the app. The extension sets the category (`one.mbm.halo.message`), the app registers it at launch and handles the action in `PushDelegate`, also when iOS starts Halo in the background for it. A reply goes through the normal send queue (`SiriSendCoordinator`), once per notification; if it can't be sent, the text is kept as the room's draft and a local notification says so. Mark as read reads the room (as in the room list), clears the room's delivered notifications and refreshes the badge; a failure is said too. **Built** (M18-7); *not verified on a device* (V-PUSH-4: the action from a terminated app, and the time iOS gives it); G-NSE needs a re-run because the extension changed.

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
- AC-N3 A reply from the lock screen with the app terminated reaches the server once, or a notification says it wasn't sent.

**NSE robustness — gate G-NSE, end of M1 (ADR-0016).** Measured on the oldest supported device class (recorded with the results),
with the app in the background, over a 100-push run of mixed encrypted DMs and group messages unless stated otherwise. The time and
memory limits are the ones *measured* in V-NSE-1, not assumed values.
- AC-NSE-1 **Memory:** peak NSE memory stays ≤ 80 % of the NSE memory limit measured on that device; zero memory terminations in the run.
- AC-NSE-2 **Execution time:** p95 time from `didReceive` to calling the content handler ≤ 50 % of the measured time budget on a normal network; `serviceExtensionTimeWillExpire` fires for none of the 100 pushes.
- AC-NSE-3 **Timeout handling:** with an injected delay that overruns the budget at each pipeline step in turn, the NSE always delivers from `serviceExtensionTimeWillExpire`: generic content (no message text) and the cached badge; it never crashes, and a `notification_record` exists only if the event had already been fetched (otherwise the app clears the notification by `room_id`, [../matrix/PUSH_NOTIFICATIONS.md](../matrix/PUSH_NOTIFICATIONS.md) §5).
- AC-NSE-4 **Extension termination:** killing the NSE at each pipeline step in turn leaves `halo.sqlite` consistent (every write committed or rolled back), the next NSE process and the app both acquire the SDK's cross-process lock and proceed without user action, and the notification iOS showed is cleared once the room is read; no `0xdead10cc` terminations while the app writes in the background (V-SQL-2).
- AC-NSE-5 **Network failures:** with the homeserver unreachable, timing out, or answering 5xx (fault-injection proxy), the NSE delivers generic content within the budget, never shows content it couldn't fetch and decrypt, writes no `notification_record`, and the next app reconcile corrects attention and the badge.
- AC-NSE-6 **Fallback behaviour:** in every degraded path (timeout, termination, network failure, UTD, all-rooms badge over budget per V-NSE-2) the badge the NSE sets is `BadgeCalculator` over local state or the cached last value of it — never a payload value (D65) — and no event is notified twice (AC-U7).

## 12. Test requirements
Unit: the NSE pipeline as a pure function with fakes (de-dup, suppress, content building), including every degraded path of AC-NSE-3…6. Device (G-NSE): the AC-NSE run with fault injection through the pipeline's injected ports and a debug-only delay/kill hook (compiled out of Release builds) plus the `infra/test` proxy for network faults; results recorded in the M1 exit report. Integration: S-PUSH-1..4 with a fake push gateway that calls the pipeline directly (no APNs). Manual: device checklist ([../testing/TEST_STRATEGY.md](../testing/TEST_STRATEGY.md) §8).

## 13. Open questions
V-NSE-1/2/3, V-PUSH-1..5, V-SQL-2 (all inputs to G-NSE).
