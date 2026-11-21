# Halo — Session Handoff

Last updated: 2026-11-21 · Branch: `main` · PRs #1–#48 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** M0 done; M1 largely done; M2 done (offline-send test and kill-and-relaunch resend verified); **M3 (read-state engine) in progress**. Dev Mac: Xcode 27.2, Swift 6.4.2, iPhone 16.
- **Checks:** `scripts/prepush.sh` passes (SwiftLint not configured, skipped); `scripts/prepush.sh` now also builds `Halo-Debug` for the simulator. All 17 contract tests (`infra/dev`) pass, none skipped (`scripts/contract-test.sh` after `infra/dev/create-fixtures.py`).
- **CI:** PRs #1–#15 merged. CI runs only the Linux-portable packages (Foundation, Domain, TestSupport, Application): adapter, persistence, platform, features and the app are tested only by `prepush.sh` on a Mac. `licenses` runs only on SDK/inventory changes.

- **Codebase review (2026-11-21):** [docs/CODEBASE_REVIEW.md](docs/CODEBASE_REVIEW.md), 27 findings (7 P0, all unread/badge), Top 10 risks, Phase 0–3 roadmap. **Fixed:** R-01 (D78), R-07 (D79), R-02/R-03/R-13 (record lifecycle + GRDB `notification_record`), R-04 (carry-over completeness), R-05/R-08 (`ReadStateCoordinator` + `NotificationProcessor`). Next in Phase 0: R-06 (ADR revisiting D47/D72), R-10/R-12, R-09.
- **Loop state (2026-11-21, paused):** the small unblocked items are done (this session: timeline receipts/location/polls/calls/reply jump, Sticker packs, notification defaults and mention toggles, room info refresh; all but a few taps seen in the simulator). What is left is large or needs a decision: see §6 "Candidates". Restart with `/loop` once the founder picks one.
- **Earlier loop state (2026-11-20):** what is left that needs no device, signing, gate decision or product decision is small polish: the bot reaction menu (FR-4, product detail), V-ST-2 (needs an expiring token the dev Synapse can't give). The loop paused here; restart it to take those.

## 2. Completed work (what exists now)
Summary only; details per feature: [docs/development/IMPLEMENTATION_NOTES.md](docs/development/IMPLEMENTATION_NOTES.md).
- Architecture: HaloFoundation, HaloDomain, HaloApplication, HaloPersistence (GRDB), HaloMatrixAdapter (only MatrixRustSDK importer), HaloPlatform, HaloTestSupport, Features/{Auth,RoomList,Timeline,Stickers,Settings}; composition root `ios/App/AppRoot.swift`; XcodeGen project (`Halo-Debug`).
- Read state (M3): policy-driven badge, outbound receipts, unread indicators, jump-to-unread, classic-sync adapter, auditor, scenarios S01–S24 as model tests.
- Messaging (M2): send/retry/abort, drafts, mentions, photo send with caption, offline resend; media previews (hide/reveal, video thumbnails).
- Stickers (M4): packs, panel, recents, create pack, remove unavailable packs.
- Room info (M5): info button in the timeline → sheet with details, members, notification mode, leave (PR 45).
- Settings (M5): Account, Privacy (private receipts), Media (show photos), Appearance (theme), Security (status), Notifications (status), Storage (sizes), Diagnostics (report), About, Acknowledgements.

## 3. Key decisions
**D73 (founder): V-RS-7 closed.** Classic Matrix sync is the authoritative unread evidence on the production path; push records supplement it; server zero never marks read by itself; a partial or empty evaluation never overwrites the stored attention set; badge from reconciled state; no SDK/Synapse change unless proven necessary; unread correctness and badge persistence are **P0**. Verified: the SDK exposes per-room evidence over `syncV2` (`ClassicSyncEvidenceTests`); classic sync does not solve the NSE's background state (records + cached set stay its inputs). **Implemented by D74:** the adapter runs classic sync (own `syncOnceV2` loop, 8 s long poll), room list from `client.rooms()` plus the rooms each response changed; verified live in the simulator (unread `@1` and bold within seconds).

**D78 (founder approved the R-01 fix):** in an encrypted room the SDK's counts decide whenever any is non-zero (E3b); server counts with all SDK counts at zero are no unread (E3c, `ENC_SERVER_ONLY`). Evidence F-SDK-3.
**D79 (founder approved the R-07 fix):** E1/E1b give way to positive SDK counts once the SDK has applied the read position (its receipt ≥ the local one, or the own latest event is on the server); a local position ahead of the receipt and a pending echo still clear at once.

Full list: docs/DECISION_LOG.md (D1–D79), docs/adr/. Most relevant now: D70 autonomous loop with self-merge (docs/development/AUTONOMOUS_LOOP.md); D5/D9 badge = rooms needing attention; D47 `readPosTs` vs `notifiedThroughTs`; D6 visibility rule; D7 private receipts; D17 unthreaded receipts; D65/ADR-0015 pushes never set the badge.

## 4. Modified files (this push)
Earlier pushes: `git log`.
- **R-05 / R-08 (`ReadStateCoordinator` + `NotificationProcessor`):** `HaloApplication` (`ReadState/ReadStateCoordinator.swift` replacing `Badge/BadgeCoordinator.swift`, `Notifications/NotificationProcessor.swift`), `FeatureRoomList` (`RoomListViewModel.swift` consumes `ReadStateCoordinator`, no `ReadStatePolicy` calls), `HaloDomain` (`NotificationFetchPort.swift` room `mode` + `isInvite`), `HaloMatrixAdapter` (`MatrixNotificationPort.swift` resolves room mode), `HaloPlatform` (`SystemBadge.swift` `AttentionCache.setForeground`/`isForeground`/`roomIDs`), `HaloTestSupport` (`FakeNotificationFetchPort.swift`), `ios/App/{AppRoot,HaloApp}.swift`, `ios/NotificationService/NotificationService.swift`, `ios/project.yml` + `Halo.xcodeproj`, `scripts/check_boundaries.py`.
- **Tests:** `RoomListViewModelTests.roomListAndBadgeAlwaysAgree` (PS31), `NotificationProcessorTests` (PS32 + display/encrypted/duplicate/suppressed/error), `AttentionCacheTests`.
- **Docs:** `docs/CODEBASE_REVIEW.md`, `docs/ROADMAP.md`, `HANDOFF.md`.

## 5. Outstanding issues
Unverified items, known limits and test notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Contract suite (2026-11-21):** 29/30 pass against `infra/dev`; `MediaPortContract` fails (the first image it finds in `HALO_DEV_TIMELINE_ROOM` isn't `blue.png`). It fails the same way without this push's changes (checked with the changes stashed): fixture state, probably a later image posted into that room. Fix the fixture or make the test look for `blue.png` by name.
**Prepush on this Mac:** the default simulator `iPhone 17` (and `iPhone 16`) isn't installed; run `HALO_SIM="iPhone Air" scripts/prepush.sh`.

**Needs the founder** (the loop records these and moves on; AUTONOMOUS_LOOP §5)
- 📱 Device checks: G-NSE AC-NSE-1…6, V-RS-1, file protection on `halo.sqlite`, NSE database access, background push delivery.
- 👤 Gate outcomes G-UNREAD / G-FFI: evaluation written ([testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md)); agent recommends G-FFI **pass** (stay upstream, two conditions) and G-UNREAD **stay open** until the classic-sync adapter and the S01–S22 re-run are done (V-RS-7 decided: D73) and the 📱 checks are done; push gateway, APNs keys, TestFlight.

**Deferred (not blocking):** Q-CI-MAC (D71, founder): no macOS CI job for now; `scripts/prepush.sh` stays the only Mac validation gate. Revisit once the build pipeline is stable and a hosted runner is confirmed to have the required Xcode.

## 6. Next steps
The queue is docs/ROADMAP.md §"Remaining work", worked by the loop in docs/development/AUTONOMOUS_LOOP.md.
0. **Review Phase 0 (P0, correctness first):** docs/CODEBASE_REVIEW.md §14, in order: R-06 (PR + ADR revisiting D47/D72), R-10/R-12, R-09; then Phase 1–3.

**Candidates for the founder to pick** after Phase 0 (each is a PR-sized feature or needs a decision):
1. **M7 Bot Activity** slices 1–3 are merged/pushed (founder picked it); the rest is ROADMAP "M7 Bot Activity": nothing in M7 except `bot_action` persistence and the 👎 😝 🎉 menu (BOT_MESSAGES FR-4, product detail).
2. ~~Settings → Account → sessions/devices~~ list built (ADR-0018); remaining: sign out other sessions (needs UIA).
3. **Storage → clear cache** (forces a full resync; needs the sync loop stopped and restarted) and **Security → disable recovery** (destructive; needs its confirmation copy).
4. **TIMELINE** leftovers (founder picked these; **all three done**, remaining: tap-for-all-readers, receipts under others' messages, `TimelineFocus.Event` beyond ~200 events): ~~read-receipt avatars (FR-6)~~ done, ~~loading older history for a reply original~~ done (bounded), edit history (P2).
5. **M5**: MAS in `infra/dev` and OIDC login (V-AUTH-1), QR/emoji verification, the performance pass (needs a large account/device).
Device and gate items stay in §5 "Needs the founder".

## 7. Next Session Prompt
```text
/loop Continuously execute the roadmap in a loop: **Plan → Implement → Verify**. Once a milestone is completed and verified, immediately proceed to the next milestone. Continue autonomously until roadmap finished.

Context for the loop (Halo, repository evan1ee/halo):
1. Read AGENTS.md, HANDOFF.md, then docs/development/AUTONOMOUS_LOOP.md. Trust HANDOFF for project state.
   Run scripts/install-hooks.sh once per clone.
2. The work queue is docs/ROADMAP.md §"Remaining work"; HANDOFF §6 is its head. Small items: commit to main; PR only for milestones and big features (D75). Wait ~2 min between loop iterations.
3. Verify every SDK API in the pinned source (ios/SDKVERSION.md); never invent names.
4. Verify each item: scripts/prepush.sh, the Halo-Debug app build, touched contract tests against infra/dev,
   a simulator check for UI. Report real output; say what you couldn't run.
5. Review the diff; fix high/medium findings. Merge your own PR only under AUTONOMOUS_LOOP §3 (all CI checks
   passed, `gh pr merge --merge --delete-branch`), then branch again from main.
6. Device, signing, gate-outcome, dependency and product decisions go to HANDOFF §5 "Needs the founder";
   move on to the next item instead of stopping. Do not ask whether to continue.
7. Before every git push (AGENTS.md §18): HANDOFF.md rewritten as state and next steps, ROADMAP ticked,
   specs/OPEN_QUESTIONS/DECISION_LOG updated, HANDOFF.md in the last commit of the push.
```
