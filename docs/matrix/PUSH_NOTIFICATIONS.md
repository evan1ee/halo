# Push Notifications

Decisions: D10, D11, ADR-0010. Feature behaviour: [../features/NOTIFICATIONS.md](../features/NOTIFICATIONS.md).

## 1. Infrastructure

```mermaid
sequenceDiagram
  participant HS as Synapse
  participant SY as Sygnal
  participant AP as APNs
  participant NSE as HaloNotificationService
  participant DB as halo.sqlite
  participant NC as Notification Center
  HS->>SY: push (event_id_only: room_id, event_id, counts)
  SY->>AP: alert push, mutable-content=1
  AP->>NSE: didReceive(request)
  NSE->>NSE: build client (MultipleProcesses), NotificationClient.get_notification
  NSE->>DB: insert notification_record (PK event_id) — duplicate? → suppress
  NSE->>NSE: ReadStatePolicy over all rooms → badge
  NSE->>NC: content (title, body, threadIdentifier=room_id, badge)
```

## 2. Pusher registration
- `Client.set_pusher(identifiers, kind, app_display_name, device_display_name, profile_tag, lang, append)` **[VERIFIED F-FFI-4]**; kind HTTP with `url = https://<sygnal>/_matrix/push/v1/notify`, `format = event_id_only`, `PusherKind.Http{data: HttpPusherData{url, format: .eventIdOnly, default_payload}}` **[VERIFIED F-FFI-16]**, with `default_payload` setting `aps.mutable-content = 1` and a generic `aps.alert` **[ASSUMPTION V-PUSH-1: Sygnal's APNs payload mapping of `default_payload`; verify against the Sygnal docs at M1]**.
- `app_id` = bundle ID (+ `.dev` for the sandbox APNs environment) → Sygnal config.
- Re-register on every launch if the APNs token changed; `delete_pusher` on logout.

## 3. NSE pipeline
1. `init_platform` (lightweight runtime) once per process; build the client with `CrossProcessLockConfig.MultiProcess { holderName: "nse" }` **[VERIFIED F-FFI-10/13]**.
2. `NotificationClient.get_notification(room_id, event_id)` **[VERIFIED F-FFI-10]** → `NotificationStatus`:
   - `Event{item}` → step 3
   - `EventFilteredOut` → suppress (with entitlement) or a generic placeholder
   - `EventRedacted`, `EventNotFound` → suppress / placeholder
3. De-duplicate: insert `notification_record`; if the PK already exists → suppress (AC-U7).
4. Already read? If the room's `readPosTs ≥ event ts` → suppress.
5. Should notify? Use `item.is_noisy`, `item.has_mention` (on-device push-rule evaluation by the SDK) **[VERIFIED F-FFI-10 field names]** together with the room's mode.
6. Content: communication notification (`INSendMessageIntent`) with the sender's name and avatar, body (or "Sticker", "Image" …); `threadIdentifier = room_id`; `request identifier = event_id`.
7. Badge = `BadgeCalculator` over the policy inputs for all rooms that can be loaded within budget **[ASSUMPTION V-NSE-2: reading RoomInfo for all rooms in the NSE fits the time/memory budget; fallback = cached last badge ± this event's room]**.
8. Timeout (`serviceExtensionTimeWillExpire`) → deliver generic content with the cached badge.

**Suppression requires** `com.apple.developer.usernotifications.filtering` **[ASSUMPTION V-PUSH-3: Apple grants it; request in M1]**.
Without it, "suppress" becomes a low-relevance generic notification that the app removes on the next run.

## 4. Payload counts
The push payload's `counts.unread` is the server's count and is **ignored** for the badge (cause C5).

## 5. Clearing delivered notifications
When `readPosTs` for a room moves forward (any source):
`getDeliveredNotifications` → remove those with `threadIdentifier == room_id` and `event_ts ≤ readPosTs` (looked up via
`notification_record`) → delete those records → `setBadgeCount(badge)`.
Triggers: every reconcile in the app, background push wake-ups, BG refresh (D11).

## 6. Failure modes

| Failure | Behaviour |
|---|---|
| NSE killed (memory) | iOS shows the original alert from the payload: Synapse's `default_payload` alert text must be a generic "New message" (no content) |
| Keys missing (UTD) | "Encrypted message" placeholder; once the app decrypts later, notification content isn't updated (iOS limitation) |
| Sygnal down | No pushes; the app catches up on foreground; the settings screen shows push health from the last delivery time |
