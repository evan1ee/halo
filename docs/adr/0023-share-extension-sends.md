# ADR-0023: The share extension sends through the SDK

- **Status:** Accepted
- **Date:** 2026-11-22
- **Decision IDs:** D92 (refines D87)
- **Validation:** V-SHARE-1 (device: encrypted-room send from the extension while the app is closed and while it is open)

## Context
D87 made the share extension a stager: it copied what was shared into the App Group and the app sent it later. On a device this left the person in the source app with an extra step (open Halo, pick a chat), and iOS gives a share extension no public way to open its app. The founder wants sharing to finish inside the share sheet.

## Problem
Pick a chat and send, without opening Halo, without breaking AGENTS §17 (no `SyncService` in an extension, no second copy of Matrix state) or the cross-process rules of the notification extension (ADR-0016, R-23).

## Considered alternatives
1. **Keep staging, add a local notification.** Works with notifications on; still one more tap. Kept as the fallback.
2. **Pick the chat in the extension, queue, let the app send later.** One step fewer, but the message is not sent until Halo runs: dishonest "sent" UI (AGENTS §4.4).
3. **Send from the extension with the SDK.** Truly one step; the extension needs the Keychain session and a second SDK client on the shared store.
4. **Open the app through the responder chain.** Unsupported API; App Review risk; rejected.

## Decision
Option 3, with 1 as the fallback. The extension stages first (nothing is lost), restores the SDK session from the shared Keychain the way the NSE does (`holderName: "share"`, `sendsMessages: false`, lightweight runtime, no sliding sync), lists joined chats from the SDK's local store (`MatrixShareTargetPort`, no sync), and sends through the normal `TimelineSession` (`ShareCoordinator`). It waits up to 90 s for the server's echo (`SendConfirmation`) before closing. If there is no session or the store can't be read, it keeps the staged items and posts a content-free notification that opens Halo.

## Rationale
The SDK's cross-process lock is designed for the app and its extensions on one store (the NSE already relies on it). Unconfirmed sends stay in the SDK's send queue in the shared store, so if iOS stops the extension early, Halo (which owns the queues, `sendsMessages: true`) finishes them: the result is "queued", never silently lost.

## Trade-offs
A second SDK client in a second process: memory (about the NSE's footprint plus uploads held in memory, capped at 50 MiB) and a small window where both processes run. The extension must not own the send queues, so a message it could not push in 90 s waits for the next app run.

## Consequences
- `HaloShareExtension` links `HaloMatrixAdapter` and `FeatureRoomList`, and gets the Keychain access group.
- The extension still never starts `SyncService`, never sends receipts, and never writes read state.
- MODULE_BOUNDARIES lists the new dependencies.

## Verified facts and assumptions
- [VERIFIED] `MatrixSessionPort` already supports a second holder, `sendsMessages: false` and a lightweight runtime (NSE, ADR-0016).
- [ASSUMPTION, V-SHARE-1] Encrypted rooms send correctly from a second process on the shared crypto store while the app is closed or open.
- [ASSUMPTION, V-SHARE-1] iOS keeps the extension alive long enough for uploads of typical photos.
