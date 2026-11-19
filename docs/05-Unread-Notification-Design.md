# Halo — Notification and Unread State Design

Status: v0.1. Decisions: D5–D11, D17, D35. This is the P0 differentiator; it is designed below the UI level.

## 1. What Matrix defines

| Concept | Where it lives | Meaning |
|---|---|---|
| `m.read` receipt | Ephemeral `m.receipt` event in the room (public) | "User has read up to event E" (and everything before it). Others see it |
| `m.read.private` | Same, visible only to the user | Same meaning, not shown to others. Supported in the spec since v1.4 |
| Threaded receipts | `thread_id` on the receipt (`main` or a thread root; omitted = unthreaded) | Since v1.4 (MSC3771). An unthreaded receipt covers all threads |
| `m.fully_read` | Room **account data** (per user) | The "read marker": where the user has scrolled to. UI only; servers don't use it for counts |
| `m.marked_unread` | Room account data (v1.12, was MSC2867) | The user manually marked the room unread |
| `unread_notifications` | Sync response per room: `notification_count`, `highlight_count` | **Server-computed**: events after the user's latest (`m.read` or `m.read.private`) receipt whose push-rule result is `notify` / highlight |
| `unread_thread_notifications` | Same, per thread (if requested) | MSC3773 |
| Push rules | Account data `m.push_rules` | Decide notify / highlight / sound per event |

Consequences:

1. **The server has the truth about the read position** (the latest receipt) but can only count properly what it can read.
2. In **encrypted rooms** the server can't evaluate content rules (mentions, keywords). The default
   rules `.m.rule.encrypted_room_one_to_one` / `.m.rule.encrypted` mark almost every encrypted
   message as `notify`, and highlights can't be detected. So `notification_count` in encrypted rooms is
   "messages since the receipt" (close to an unread count), and `highlight_count` is ~always 0.
3. Only the client can compute an accurate per-event notify/highlight result for E2EE, after decryption.

## 2. How matrix-rust-sdk computes unread (verified at rev 7ff8855)

- `matrix-sdk-base::read_receipts::ReadReceipts` per room keeps `num_unread`, `num_notifications`,
  `num_mentions`, `latest_active` (the latest main or unthreaded receipt) and `pending`, a **ring buffer of 10**
  receipts whose target event isn't in the local cache (yet).
- The counts are updated by the event cache in `matrix-sdk` as events and receipts arrive. Events
  after the latest active receipt are counted, with push rules evaluated on the device for decrypted events.
- Exposed through `RoomInfo` (FFI: `num_unread_messages`, `num_unread_notifications`,
  `num_unread_mentions`) next to the server's `notification_count` / `highlight_count`.

## 3. Why badges go wrong (root-cause catalogue)

| # | Cause | Effect |
|---|---|---|
| C1 | **Gap**: sliding sync returns a limited timeline; events between the receipt and the newest event are missing locally | The device count is wrong (too low, or the receipt isn't found) |
| C2 | **Receipt for an unknown event** (it's in the gap, or federation is lagging) goes to `pending`; more than 10 pending entries are dropped | A read elsewhere is never applied → **"read but still badged"** |
| C3 | **Missing receipts for rooms that aren't open**: the receipts extension isn't active for that room in sliding sync | The device never learns about the read on another device |
| C4 | **Late decryption** (keys arrive later): events counted before decryption ("encrypted", notify) and re-evaluated after | The count jumps; can disagree with the push that was shown |
| C5 | **Two writers**: the app and the NSE update counts/badges separately; the NSE sets `badge` from the push payload (server count) | The badge differs from the in-app state; it gets stuck until the app runs |
| C6 | **Badge set incrementally** (`+1` per push) rather than recomputed | Errors add up and are never corrected |
| C7 | **Receipt not sent**: the app was suspended before the request finished; no retry | The server (and other devices) think it's unread → re-badged after the next sync |
| C8 | **Receipt moved backwards** (receipt sent for an older event after a newer one) | Servers ignore it, but the local state may apply it |
| C9 | **Threads**: thread messages counted, but the receipt only covers `main` | Phantom unread |
| C10 | **Unread vs notify confusion**: a room with only non-notifying messages shows a badge, or the other way round | The user sees it as "wrong" |
| C11 | **Delivered notifications are not removed** when read elsewhere | Stale banners and lock-screen items |
| C12 | **Redacted or edited unread events** stay counted | Phantom unread |

## 4. State model

Per room (owned by `halo-unread`, persisted in `halo-store`):

```text
RoomReadState {
  room_id
  read_position: { event_id, origin_server_ts, stream_order? , source: Local|OwnDevice|Server }
  fully_read:    event_id?                       // UI read marker only
  marked_unread: bool                            // m.marked_unread
  mode:          AllMessages | MentionsAndKeywords | Mute     // from push rules
  counts:        { unread, notify, highlight }   // derived, never edited by hand
  confidence:    Exact | LowerBound | ServerFallback
  server:        { notification_count, highlight_count, seen_at }  // latest sliding sync values
  receipt_outbox: { event_id, kind, attempts }?  // receipt not yet acknowledged by the server
  version:       u64                             // increases on every change; for cross-process checks
}
```

Derived predicates (one implementation, used by the room list, the app badge and the NSE):

```text
needs_attention(r) =
     r.marked_unread
  || (r.mode != Mute && r.counts.highlight > 0)
  || (r.mode == AllMessages && r.counts.notify > 0)
  || r.is_invite
badge = count(rooms where needs_attention)          // D5
```

### Source-of-truth rules

1. **Read position: the furthest of (server receipt, local receipt not yet acknowledged).** Never
   move backwards (`max` by timeline order, falling back to `origin_server_ts` when order is unknown). This fixes C8.
2. **Counts are derived** from (read position, cached events after it, push-rule evaluation).
   Never increment them; recompute them for a room when any input changes. This fixes C6.
3. **The server's zero is authoritative.** If the server reports `notification_count == 0 &&
   highlight_count == 0` for a room in a sync response that came *after* our latest local event for
   that room, the user has read up to at least our latest notifying event on some device. Fetch
   the receipt if it's missing locally, and set `notify = highlight = 0` now. This is the main fix for C2/C3 ("read
   elsewhere but still badged").
4. **The server's non-zero only gives a lower bound on a gap.** When `confidence != Exact`, use
   `notify = max(local, server.notification_count)` in **unencrypted** rooms; in encrypted rooms use the server value only as
   "≥1 unread" evidence. This fixes C1.
5. **Confidence**:
   - `Exact`: the read position event is in the cache and every event after it is cached and decrypted (or known to be undecryptable).
   - `LowerBound`: there's a gap after the read position, or UTD events are pending decryption.
   - `ServerFallback`: the read position isn't in the cache and the backfill budget has run out.
   In the UI, a room that needs attention shows an exact count, or "•"/"9+" style for non-Exact rooms. The badge (a count of rooms) doesn't depend on exact counts.

### Relation to the SDK

`halo-unread` is a **pure function** `(inputs) → RoomReadState`. Its inputs are taken from the SDK: room events
(event cache), receipts (from `RoomInfo`/sync), server counts, push rules, account data. We don't
fork the SDK. We use our own engine instead of `num_unread_*` because we need confidence, the
server-zero rule, the outbox and identical results in two processes. The SDK's own numbers are kept for
comparison in the auditor, and any disagreement is logged.

## 5. Receipts — sending and receiving

**Sending (D6, D7):**
- The visibility tracker in the timeline reports the newest *fully visible* event once it has been visible
  for ≥0.5 s with the app active (`scenePhase == .active`) and the room on screen.
- The engine does the local update **first**: read position = that event (if it's ahead), source `Local`, outbox entry
  written in the same transaction → the badge is recomputed at once.
- Network: one `POST /rooms/{id}/read_markers` with `m.read` (or `m.read.private`) **and**
  `m.fully_read` together; unthreaded receipts (D17). The outbox is cleared when the server acknowledges, or when a
  sync shows a server receipt at or beyond it.
- Retries: exponential backoff; flushed on reconnect, on foreground, and from a `beginBackgroundTask`
  when the app is backgrounded. This fixes C7.
- Debounce: at most one request per room per 2 s; always the latest position.

**Receiving:**
- Sliding sync: enable the **receipts extension for every room-list list/subscription that
  feeds the badge** (all joined rooms, not just visible ones), plus the account_data extension (for
  `m.fully_read`, `m.marked_unread`, push rules). This fixes C3.
- Own receipts from other devices → read position (source `OwnDevice`). Other users' receipts → display only.
- A receipt whose event isn't cached → `pending` in **our** store (no 10-entry limit; we keep the latest receipt per
  thread, which is all we need), then backfill (§7).

## 6. Push notification handling (D10, D11)

Path: Synapse push rules → Sygnal (`event_id_only`) → APNs → **HaloNSE**.

The NSE, for each push:
1. Take the cross-process lock and open the session read-mostly.
2. `NotificationClient` fetches and decrypts `(room_id, event_id)`.
3. Evaluate push rules locally on the decrypted content (SDK).
4. Feed the event into `halo-unread` for that room (bump `version`).
5. Decide:
   - shouldn't notify (rules, already read by a newer receipt, muted) → with the filtering
     entitlement: deliver an empty notification (suppressed); without it: generic text, `relevance` low.
   - should notify → a communication notification: `threadIdentifier = room_id`,
     `request identifier = event_id`, `badge = recomputed badge()`.
6. Never use the server's `counts.unread` from the payload as the badge (C5).
7. Release the lock. Time budget: aim to finish in under 10 s; on timeout, generic content plus the last known badge.

**Clearing (C11):** whenever the read position for a room moves forwards (any source), remove delivered
notifications in that `threadIdentifier` whose `event_id` is at or before the read position
(`UNUserNotificationCenter.getDeliveredNotifications` → `removeDeliveredNotifications`), then
`setBadgeCount(badge())`. Triggers: in-app sync, background refresh, a background push from Synapse
(it sends a push with no event when counts change: when it's delivered as a background push, the app runs a
short reconcile). Best effort; full reconcile on every foreground (D11).

## 7. Recovery mechanisms

| Situation | Detection | Action |
|---|---|---|
| Gap after the read position (C1) | The sync response is `limited`, or the event cache reports a gap | `confidence = LowerBound`; schedule a backfill (paginate backwards until the read position is found or 200 events/room); then recompute |
| Receipt for an unknown event (C2) | Lookup misses | Keep it as the pending position; backfill; if not found within budget → `ServerFallback` |
| Server zero vs local unread | Rule 3 | Apply zero, refetch the receipt, log to the auditor (counts as an *explained* correction) |
| Late decryption (C4) | Room key arrives (SDK UTD hook / decryption retry) | Recompute the room; if a notification that shouldn't have shown was displayed, leave it, but correct the badge |
| Reconnect / app killed / long offline | `SyncService` restarts | For each room in the first sync: compare the server counts and receipts with the stored state; recompute; flush the outbox |
| Store corruption or schema mismatch | Open fails / integrity check | Drop `halo.sqlite` engine tables (keep the outbox if readable) → rebuild from the SDK plus the server |
| Thread receipts (until M9) | — | Count thread events inline; unthreaded receipts cover them (D17, fixes C9) |
| Redaction or edit (C12) | Redaction event | Recompute: redacted events don't count; edits don't add to the count |

## 8. Testing strategy (D35)

### 8.1 Pure engine (`halo-unread`, Rust, Linux CI)
Example-based tests for every row in §3 and §7, plus **property tests (proptest)** over random
event/receipt/sync interleavings. Invariants:
- I1 Reading the latest event → `notify = highlight = 0` and `!needs_attention` (unless `marked_unread`).
- I2 The read position never moves backwards.
- I3 Order independence: applying the same set of inputs in any order gives the same final state.
- I4 Idempotence: applying an input twice = applying it once.
- I5 `server zero` (after the latest local event) ⇒ `notify = 0`.
- I6 `confidence == Exact` ⇒ the counts equal a brute-force recount over the event list.
- I7 `badge() == |{r : needs_attention(r)}|` for every state.
- I8 The app path and the NSE path (serialised and reloaded) give the same badge.

### 8.2 Scenario tests against a real Synapse (Docker, Linux CI)
The harness (`halo-testkit`) drives users A (Halo engine under test, headless Rust client) and B, C
(other clients), plus A's "second device" A2. Scenarios:
1. B sends 5 messages, A reads on A2 → A's room is not unread after sync.
2. A offline for 300 messages across 20 rooms (gaps) → reconnect → the badge is correct; confidence is resolved.
3. Receipt for an event in the gap.
4. A2 reads while A is "suspended" (no sync), then A syncs with a limited timeline.
5. Encrypted room with a mention, keys delivered late.
6. Redaction of the only unread message.
7. `m.marked_unread` set on A2.
8. Mute/mentions-only mode changes on A2 (push rules).
9. A sends a receipt, network down → retry → server acknowledges (outbox).
10. Thread messages (D17 behaviour).
Each scenario checks the server's view (receipts via the API) against A's engine state.

### 8.3 Sync replay
Record sliding-sync responses (dev builds, opt-in, content removed: bodies hashed, keys removed) and
replay them through the engine; a reported bug becomes a regression fixture.

### 8.4 On-device auditor (debug and TestFlight builds)
Every N minutes and on every foreground: for each room compare (engine state, SDK `num_unread_*`,
server counts, latest receipts). Group disagreements into *explained* (gap, pending decryption)
and *unexplained*. Store snapshots; "Export diagnostics" shares an archive with private content removed. AC-U6: zero
unexplained over a 7-day soak.

### 8.5 Device tests (manual checklist per release)
Lock-screen push for an encrypted DM; read on the Mac → the iPhone banner disappears; airplane mode for 1 h;
force-quit during sync; low-power mode; 300-room account.
