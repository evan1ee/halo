# Unread / Read-State Regression Tests

Specification under test: [../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md). Gate **G-UNREAD** = all of §2 and §3 green.

## 1. Unit tests (one per rule)
For each rule E0–E5 × each mode (all / mentions / mute) × encrypted/unencrypted: expected `attention`, `display`, `confidence`, `reasons`.
Plus: badge counting, display formatting (99+), reason codes for the auditor.

## 2. Property tests (seeded generators; seed printed on failure; 10,000 cases in CI)

| ID | Property |
|---|---|
| P1 | If a local intent covers the latest event and nothing newer was notified, `attention == markedUnread ∨ invite` |
| P2 | `evaluate` is total: no crash, and `display == .none ⇔ !attention ∧ !hasUnread` |
| P3 | **Order independence**: applying the same multiset of snapshot updates (by sequence) in any order yields the same final state |
| P4 | **Idempotence**: re-applying any input leaves the state unchanged |
| P5 | Server zero (both counts 0), no unconfirmed notified events, not marked, not invited ⇒ `!attention` |
| P6 | A notified event newer than every read position ⇒ `attention` (in all-messages mode; or if it's a mention in mentions mode) |
| P7 | `badge == |{r : attention(r)}|` and is identical for app and NSE code paths after serialising/deserialising inputs through the DB |
| P8 | The intent store never moves a room's intent backwards under concurrent upserts |

## 3. Integration scenarios (Synapse in Docker; scenario driver)

Actors: **A** = the Halo user on device A1 (under test); **A2** = the same user's second device; **B**, **C** = other users.

| ID | Scenario | Expected at the end |
|---|---|---|
| S01 | B sends 5 messages in a DM; A1 views them | A1: no attention; server receipt at the 5th; badge 0 |
| S02 | B sends 5; A2 reads them; A1 syncs | A1: no attention (E2) within one sync; delivered notifications cleared |
| S03 | B sends 1; A1 was offline; A1 receives the push first (NSE path) then syncs | Attention from the push (E4) → still attention after sync → cleared after viewing |
| S04 | 300 messages over 20 rooms while A1 is offline (limited timelines), A2 reads 10 rooms | A1 after reconnect: exactly the 10 other rooms have attention |
| S05 | A2's receipt targets an event inside A1's gap | A1: no attention for that room |
| S06 | Encrypted group room, B mentions A; keys arrive late on A1 | Attention with `.dot` (E3c) → becomes `.mentions(1)` once decrypted |
| S07 | Encrypted room in mentions-only mode, B sends 3 messages without mention | No attention; `hasUnread` true |
| S08 | The only unread message is redacted | No attention |
| S09 | A2 marks the room unread | A1: attention (`MARKED_UNREAD`) → A1 opens the room → flag cleared on the server |
| S10 | A2 mutes a room that has unread messages | A1: attention gone |
| S11 | A1 views the latest event while the network is down; then restarts the app; then the network returns | Attention cleared immediately, stays cleared across the restart (intent), receipt sent after reconnect |
| S12 | Receipt send fails 3 times (proxy blackhole) | Intent stays `pending`; retries with backoff; no attention meanwhile |
| S13 | A1 sends a message in a room with unread messages | Attention cleared (E1b) |
| S14 | Thread replies by B in a room A1 has read up to the root | Attention (thread events count); viewing them (inline) clears it via an unthreaded receipt |
| S15 | B edits an old message | No new attention; no second notification |
| S16 | Push for event X delivered twice (APNs retry) | One notification (AC-U7) |
| S17 | A1 in the background; A2 reads; a background push arrives | A1's delivered notifications for the room removed; badge updated (best effort — asserted in the local FFI run with a direct pipeline call) |
| S18 | B's server clock skewed by −10 min | Ordering limitation documented; no phantom unread after A1 views the latest event |
| S19 | 50 rooms change state while the app reconciles (concurrency) | Final state equals a fresh evaluation |
| S20 | App killed between "intent written" and "receipt sent" | After relaunch the outbox sends the receipt; A2 sees the room as read |

## 4. Regression procedure
1. Reproduce with the auditor export or a recorded trace.
2. Add the trace as a fixture (`HaloDomainTests/ReadState/Fixtures/<issue-id>.json`) with the expected final state.
3. If the bug needs server behaviour, add an S-scenario.
4. Fix; all of §1–§3 must be green.
