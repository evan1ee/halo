# M3 gate evaluation: G-UNREAD and G-FFI

Written 2026-11-20 by the autonomous loop from the repository state at `main` (after PR #12). **The agent evaluates; the founder
decides the outcome** (AUTONOMOUS_LOOP §5). Nothing here changes a gate: both stay **open** until the founder confirms.
Evidence labels: **tested** = automated test in this repository, **server** = checked against `infra/dev` (Synapse 1.165),
**model** = automated, but against an in-process model of Synapse, **manual** = seen once in the simulator, **open** = not checked.

## 1. G-UNREAD: does the reconciliation policy meet AC-U1–U7 in scenario tests?

| AC | What was checked | Evidence | Not covered |
|---|---|---|---|
| AC-U1 viewing the newest event clears attention, receipt sent or queued | Policy rules E1/E1b (unit, P1); `ReadReceiptCoordinator` sends or queues, restores after relaunch (tested); simulator: the receipt followed the newest visible row (manual, D6 check, 2026-11-20); S01 server half (server) | tested, manual, server | the "within 1 s" bound is not measured; the 0.5 s dwell is only unit-tested |
| AC-U2 reading on another device clears attention within one sync | S02, S05 server half: a second device's receipt reaches the first within one incremental sync, also inside a limited-timeline gap (server); policy side S02, S05 (model) | server, model | **V-RS-1** (does the SDK fire room updates for own receipts) is open and needs a device; delivered-notification removal is only tested through `SystemBadge` fakes |
| AC-U3 `badge == count(rooms needing attention)` in app and NSE | P7 (records and inputs through the store), `BadgeCoordinator` tests | tested | NSE path on a device (G-NSE AC-NSE-1…6, 📱) |
| AC-U4 convergence after kill, offline, gaps, out-of-order receipts, redaction | P3 (order independence), P4 (idempotence), S04, S05, S08, S19, S20 (model); S04, S05 server half (server) | model, server | S11, S12, S20 with a real kill and relaunch; 24 h offline |
| AC-U5 server zero where the server can count ⇒ no phantom unread | P5, P9, P10 (10,000 seeded cases each); the server rules behind it (`tools/server-rules`, 7 checks) | tested, server | **V-RS-7: Synapse's native sliding sync serves `0` for both counts**, so on the production path "server zero" carries no information and E2 never has evidence to clear against. The rule is correct where counts exist (classic `/sync`), which is what the scenario driver uses |
| AC-U6 a notifying event seen by sync or push ⇒ attention until a receipt covers it | P6, E4 notified records; S03, S06, S21, S22 (model); S22 server half: the server counts the mention inside a limited timeline (server) | tested, model, server | encrypted rooms with real keys and the SDK's own counts (S06, S21); the SDK-blind variant S22(b) is documented as a limitation |
| AC-U7 at most one notification per event id | `notification_record` primary key; `NotificationRecordStore` dedup (tested); S16 (model) | tested, model | APNs retry on a device |
| AC-U8 7-day soak, zero unexplained findings | auditor core exists (PR #12); 10,000 random inputs give no unexplained finding from the policy's own output | tested | the soak itself (👤📱); the 10-minute re-run, export and Settings counter are not built |

Other facts bearing on the gate:
- The policy is pure and total (P2) and every indicator derives from it; no stored counters (D9).
- The scenario driver covers the **server half of 9 of 22 scenarios** with real devices; the other 13 run only against the model.
  Measured server behaviours the model got wrong have been fixed twice already (own message does not reset counts; mute leaves
  existing counts), which is the case for running more of them.
- Not run anywhere: sliding sync with counts (Synapse serves none), the SDK's own counts on a device (V-RS-7 notes they were 0 for a
  room on the founder's phone), encrypted rooms with real keys.

**Assessment.** The policy layer is sound where its inputs exist and the test base is strong (properties, 22 model scenarios, server
checks). The weakness is not the policy but its inputs on the production path: with sliding sync, server counts are 0 and the SDK
sees only the newest event per room, so attention outside E4 (pushes) and E5 (marked unread) depends on counts Halo cannot get.
**Recommendation: do not close G-UNREAD yet.** Close it when (a) the V-RS-7 path is decided and S01–S22 re-run on it, and (b) the 📱
checks (V-RS-1, NSE database access) are done. This is the gate's own fail branch only if (a) shows no usable signal; until then the
"keep the policy layer" outcome is the likely one.

## 2. G-FFI: are the upstream FFI APIs enough for unread correctness and stickers?

| Need | Upstream API | Result |
|---|---|---|
| send receipts (read, private), fully-read marker | `Room.send_single_receipt`, `mark_as_fully_read_unchecked` | works (contract `ReadMarker`, server) |
| mark unread / clear flag, mark room read | `Room.set_unread_flag`, `Timeline.latest_event_id` + receipt | works (contract, simulator) |
| counts for the policy | `RoomInfo` server counts and `num_unread_*` | present; **values are 0 on sliding sync** (V-RS-7), usable on the SDK side only for events the SDK has seen |
| own receipt from other devices | `Room.load_user_receipt` | present; update triggers unverified (V-RS-1, device) |
| latest event for E1 | `Room.latest_event` | works (unit-tested mapping, `LatestEventMappingTests`) |
| pusher management | `set_pusher`, `delete_pusher` | works (contract `pusher`, server) |
| custom room state for stickers | none: room-info/state APIs return nothing for `m.room.image_pack` (V-ST-1 option A, empty on 1.165) | **gap**; Halo reads room state with an authenticated HTTP GET behind `StickerPackPort` (option B, D68); works, but bypasses the SDK and needs its own token handling (V-ST-2: refresh on 401 not exercised) |
| sticker send, media upload, mentions | `send_raw`, `sendAttachment`, `withMentions` | work (contracts, server) |

**Assessment.** Unread: the APIs Halo needs exist and behave as documented; the shortfall is data (V-RS-7), which Halo-owned bindings
over the same `matrix-sdk` would not change, since the counts come from the server and the SDK's sync. Stickers: one real gap (custom
room state), covered by a contained HTTP workaround behind a port. **Recommendation: G-FFI passes, i.e. stay on the upstream binary
framework**, with two conditions: keep the sticker state reader behind its port so it can move to the SDK if upstream adds the API,
and finish V-ST-2 (token refresh) before the first TestFlight build. The fail branch (Halo-owned UniFFI bindings, 6–10 weeks) is not
justified by anything measured.

## 3. Update after the V-RS-7 decision (D73, 2026-11-20)
The founder closed V-RS-7: classic sync is the unread evidence. Verified in the pinned SDK (`ClassicSyncEvidenceTests`, against `infra/dev`): over `syncV2` the SDK serves the server counts, highlight count, its own counts, the own receipt (also from another device) and the latest event per room. So the missing input of §1 exists; what is missing is the adapter that uses it (ROADMAP P0 "Classic sync in the adapter") and the S01–S22 re-run on it. Update 2026-11-20: the adapter exists (D74) and the real adapter output through the policy is verified for S01/S02/S09, encrypted rooms with real keys for S06/S07/S21 (`policyOverRealInputs`, `encryptedEvidence`). G-UNREAD stays open for the restart/outbox/NSE scenarios and the 📱 checks. Classic sync does not help the NSE, which cannot run a sync: its inputs stay the records and the cached attention set, now protected against being overwritten by a partial or empty evaluation.

## 4. What the founder decides
1. G-FFI: confirm **pass** (stay on upstream), with the two conditions above? [recommended]
2. G-UNREAD: keep **open** until the V-RS-7 path is decided and the 📱 checks are done? [recommended] Or close now with the gaps
   accepted?
3. ~~V-RS-7~~ decided: classic sync (D73).
