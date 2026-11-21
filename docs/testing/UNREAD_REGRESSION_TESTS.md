# Unread / Read-State Regression Tests

Specification under test: [../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md). Gate **G-UNREAD** = all of §2 and §3 green.

## 1. Unit tests (one per rule)
For each rule E0–E5 × each mode (all / mentions / mute) × encrypted/unencrypted: expected `attention`, `display`, `confidence`, `reasons`.
Plus: badge counting, display formatting (99+), reason codes for the auditor.

## 2. Property tests (seeded generators; seed printed on failure; 10,000 cases in CI)

| ID | Property |
|---|---|
| P1 | If a local intent covers the latest event and nothing newer was notified, `attention == markedUnread ∨ invite` — unless P11 applies |
| P2 | `evaluate` is total: no crash, and `display == .none ⇔ !attention ∧ !hasUnread` |
| P3 | **Order independence**: applying the same multiset of snapshot updates (by sequence) in any order yields the same final state |
| P4 | **Idempotence**: re-applying any input leaves the state unchanged |
| P5 | Server zero (both counts 0) **with `serverCanCount`**, no unconfirmed notified events, not marked, not invited ⇒ `!attention` |
| P5b | Encrypted room in mentions mode with `sdk.unreadMentions > 0` and no covering intent ⇒ `attention` even when server counts are 0 (E2x) |
| P6 | A notified event newer than every read position ⇒ `attention` (in all-messages mode; or if it's a mention in mentions mode) |
| P7 | `badge == |{r : attention(r)}|` and is identical for app and NSE code paths after serialising/deserialising inputs through the DB |
| P8 | The intent store never moves a room's intent backwards under concurrent upserts |
| P9 | `serverZero` never advances `readPosTs`: changing only the server counts never changes `readPosTs` (it may change `notifiedThroughTs`) |
| P10 | `hasUnread` under E2 follows UNREAD_STATE §5: `false` in all-messages mode; `sdk.unreadMessages > 0` in mentions/keywords or mute mode |
| P11 | If the SDK has applied the read position (its receipt ≥ the local intent covering the latest event, or the own latest event is on the server) and counts a notification, an all-messages room without a countable server zero has attention (R-07, D79) |

## 3. Integration scenarios (Synapse in Docker; scenario driver)

**Status:** S01–S29 exist as model-based tests in `HaloApplicationTests/ReadStateScenarioTests.swift`. They drive the real policy and coordinators against an in-process model of Synapse and of A1's sync, so they pin Halo's behaviour. The server rules the model assumes are checked against Synapse 1.165 by `tools/server-rules/check_server_rules.py` [VERIFIED 2026-11-20: counts per message/mention/edit/redaction/thread/receipt, mute and mentions-only rules, encrypted rooms; **a user's own message does not reset the counts** — the model was wrong about that and was corrected]. Not yet checked there: multi-device sliding sync, limited timelines, the SDK's own counts. `tools/scenario-driver/run_scenarios.py` runs the **server half** of S01, S02, S04–S10 (incl. S07b), S13–S15, S21 and S22 against `infra/dev` with real devices (own sync tokens, limited timelines, a second device's receipts, marked-unread, mute) [VERIFIED 2026-11-20, 28 checks, all as modelled (encrypted rooms use opaque `m.room.encrypted` events: the server counts them in all-messages mode and counts nothing in mentions-only mode, mention hidden); a redaction drops the count; an own message leaves the counts (E1b is the client's job); **mute leaves the existing counts in place**, so hiding them is the client's job (S10)]. **Encrypted rooms with real keys over classic sync** (`ClassicSyncEvidenceTests.encryptedEvidence`, two SDK clients, 2026-11-20) [VERIFIED]: all-messages mode: server counts 2 and the SDK counts 2 messages after decryption (S06); mentions-only mode after reading: server 0/0 (blind), the SDK counts 3 messages, 1 notification, 1 mention (S07, S21), so E3b gives `.mentions(1)` once decrypted. **Real adapter output into the policy** (`AdapterContractTests.policyOverRealInputs`, 2026-11-20) [VERIFIED]: the adapter's room list over classic sync, `ReadStatePolicy` on its real inputs: read baseline → no attention; peer messages + mention → `.mentions(1)` (`SERVER_COUNTS`); another device's receipt → no attention within a sync; `m.marked_unread` from the other device → attention (`MARKED_UNREAD`); cleared → none (S01, S02, S09 end to end). In the encrypted run the server once counted 3 against the SDK's 2 (an overcount the policy marks approximate). Not run against a server: the client-side parts (S03, S11, S12, S16–S20; decryption with real keys in S06/S21), sliding sync, encrypted rooms with real keys; a driver that feeds the real server's output into the Swift model is still to build.

Actors: **A** = the Halo user on device A1 (under test); **A2** = the same user's second device; **B**, **C** = other users.

| ID | Scenario | Expected at the end |
|---|---|---|
| S01 | B sends 5 messages in a DM; A1 views them | A1: no attention; server receipt at the 5th; badge 0 |
| S02 | B sends 5; A2 reads them; A1 syncs | A1: no attention (E2) within one sync; delivered notifications cleared |
| S03 | B sends 1; A1 was offline; A1 receives the push first (NSE path) then syncs | Attention from the push (E4) → still attention after sync → cleared after viewing |
| S04 | 300 messages over 20 rooms while A1 is offline (limited timelines), A2 reads 10 rooms | A1 after reconnect: exactly the 10 other rooms have attention |
| S05 | A2's receipt targets an event inside A1's gap | A1: no attention for that room |
| S06 | Encrypted group room **in all-messages mode** (in mentions/keywords mode the server counts nothing — see S21, S22), B mentions A; keys arrive late on A1 | Attention with `.count(1)` (E3b: the SDK counts the event it can't decrypt, F-SDK-3) → becomes `.mentions(1)` once decrypted |
| S07 | Encrypted room in mentions-only mode, B sends 3 messages without mention | No attention; `hasUnread` true |
| S07b | **Unencrypted** room in mentions-only mode, B sends 3 messages without mention; A1 then views them | Before: no attention, `hasUnread` true although server counts are 0 (E2 doesn't clear quiet unread here); after viewing: a receipt is sent for the 3rd message (server zero must not have advanced `readPosTs`) |
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
| S18 | B's server clock skewed by −10 min | No phantom unread after A1 views the latest event; a later message stamped before the read position shows and viewing it advances the receipt by timeline order (D79, D80, R-06) |
| S19 | 50 rooms change state while the app reconciles (concurrency) | Final state equals a fresh evaluation |
| S20 | App killed between "intent written" and "receipt sent" | After relaunch the outbox sends the receipt; A2 sees the room as read |
| S21 | Encrypted room in mentions-only mode; B mentions A (server counts stay 0) | A1: attention `.mentions(1)` (E2x); after A1 views it → cleared; after A2 views it instead → cleared once the SDK applies A2's receipt (auditor reports `SERVER_BLIND` meanwhile) |
| S22 | Encrypted room in mentions-only mode; A1 offline; B sends 30 messages, one of them mentioning A, so A1's next sync has a limited timeline that leaves the mention in a gap. Variant (a): the push for the mention reaches A1; variant (b): A1 has no pusher | (a) attention `.mentions(1)` from E4 before and after sync; (b) **documented limitation**: no attention until the SDK sees the event (opening the room or back-pagination); the auditor records `SERVER_BLIND` — the test asserts this exact behaviour so a change is noticed |
| S23 | Encrypted room in all-messages mode with no read position on A1 (joined, never opened); B votes in a poll (an encrypted non-message), then sends a message; A1 views it | After the vote: no attention, `hasUnread` false, `ENC_SERVER_ONLY` although the server counts 1 (E3c, D78); after the message: attention `.dot` (`ENC_SERVER_OVERCOUNT`); after viewing: no attention and server counts 0. Server and SDK halves verified by `ClassicSyncEvidenceTests.encryptedNonMessageEvidence` and `check_server_rules.py` (F-SDK-3) |
| S24 | Encrypted room in all-messages mode. (a) A1 read the room (receipt applied by the SDK); B sends a message A1 can't decrypt yet. (b) A sends a message, then B sends one A1 can't decrypt. (c) A1's read position is ahead of the SDK's receipt (not sent yet) | (a), (b): attention `.count(1)` with `SDK_UNREAD_AFTER_READ`, although the SDK's latest event is still the read (or own) event; (a) cleared after the keys arrive and A1 views it. (c): no attention (`INTENT_COVERS`): the SDK's count is stale. Verified against the real SDK by `ClassicSyncEvidenceTests.encryptedNonMessageEvidence` (R-07, D79) |
| S25 | Encrypted DM; B sends a message; NSE can't decrypt and stamps the record with the raw event's `origin_server_ts`; sync delivers & decrypts; A reads on A2 | Record superseded and pruned on sync; A1 has no attention after A2's read without opening the room (R-02) |
| S26 | Room with a notification record; A leaves the room on A2 while A1 is closed; A1 syncs (`rooms.left`) | Record pruned; badge excludes the room (R-03) |
| S27 | Sign out account X (notification records exist), sign in account Y | X's records cleared on reset and rows are scoped by account in `notification_record`; Y's badge has no X rooms (R-03, R-13) |
| S28 | Carried attention and stale notification record for a room left while the app was closed (never reappears in the room list) | Dropped after the first completed sync response of the run (`RoomListPort.syncCompletions`), while rooms present in that sync keep carry-over until their inputs arrive (R-04, R-03) |
| S29 | Two messages from B with identical `origin_server_ts`; A views only the first, then views the second | Viewing only the first does not hide the second once the first receipt is confirmed (`INTENT_STALE`); viewing the second advances the receipt to the second and brings server counts to 0 (R-06, D80, ADR-0020) |

## 4. Regression procedure
1. Reproduce with the auditor export or a recorded trace.
2. Add the trace as a fixture (`HaloDomainTests/ReadState/Fixtures/<issue-id>.json`) with the expected final state.
3. If the bug needs server behaviour, add an S-scenario.
4. Fix; all of §1–§3 must be green.
