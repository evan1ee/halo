# Halo — Session Handoff

Last updated: 2026-11-20 · Branch: `docs/handoff-slim` · PRs #1–#40 merged

State and next steps only; history is in `git log`, facts in `docs/`. Updated in the last commit of every push (AGENTS.md §18).

## 1. Current status
- **Milestone:** M0 done; M1 largely done; M2 done (offline-send test and kill-and-relaunch resend verified); **M3 (read-state engine) in progress**. Dev Mac: Xcode 27.2, Swift 6.4.2, iPhone 16.
- **Checks:** `scripts/prepush.sh` passes (SwiftLint not configured, skipped); `scripts/prepush.sh` now also builds `Halo-Debug` for the simulator. All 17 contract tests (`infra/dev`) pass, none skipped (`scripts/contract-test.sh` after `infra/dev/create-fixtures.py`).
- **CI:** PRs #1–#15 merged. CI runs only the Linux-portable packages (Foundation, Domain, TestSupport, Application): adapter, persistence, platform, features and the app are tested only by `prepush.sh` on a Mac. `licenses` runs only on SDK/inventory changes.

## 2. Completed work (what exists now)
Summary only; details per feature: [docs/development/IMPLEMENTATION_NOTES.md](docs/development/IMPLEMENTATION_NOTES.md).
- Architecture: HaloFoundation, HaloDomain, HaloApplication, HaloPersistence (GRDB), HaloMatrixAdapter (only MatrixRustSDK importer), HaloPlatform, HaloTestSupport, Features/{Auth,RoomList,Timeline,Stickers,Settings}; composition root `ios/App/AppRoot.swift`; XcodeGen project (`Halo-Debug`).
- Read state (M3): policy-driven badge, outbound receipts, unread indicators, jump-to-unread, classic-sync adapter, auditor, scenarios S01–S22 as model tests.
- Messaging (M2): send/retry/abort, drafts, mentions, photo send with caption, offline resend; media previews (hide/reveal, video thumbnails).
- Stickers (M4): packs, panel, recents, create pack, remove unavailable packs.
- Settings (M5): Account, Privacy (private receipts), Media (show photos), About, Acknowledgements.

## 3. Key decisions
**D73 (founder): V-RS-7 closed.** Classic Matrix sync is the authoritative unread evidence on the production path; push records supplement it; server zero never marks read by itself; a partial or empty evaluation never overwrites the stored attention set; badge from reconciled state; no SDK/Synapse change unless proven necessary; unread correctness and badge persistence are **P0**. Verified: the SDK exposes per-room evidence over `syncV2` (`ClassicSyncEvidenceTests`); classic sync does not solve the NSE's background state (records + cached set stay its inputs). **Implemented by D74:** the adapter runs classic sync (own `syncOnceV2` loop, 8 s long poll), room list from `client.rooms()` plus the rooms each response changed; verified live in the simulator (unread `@1` and bold within seconds).

Full list: docs/DECISION_LOG.md (D1–D74), docs/adr/. Most relevant now: D70 autonomous loop with self-merge (docs/development/AUTONOMOUS_LOOP.md); D5/D9 badge = rooms needing attention; D47 `readPosTs` vs `notifiedThroughTs`; D6 visibility rule; D7 private receipts; D17 unthreaded receipts; D65/ADR-0015 pushes never set the badge.

## 4. Modified files (this push)
Settings → Media → Show photos (`MediaPreviewSetting`, `MatrixMediaPreviewPolicyPort` rewritten to read/write both MSC4278 account-data types, picker in `SettingsView`, `AppRoot` mapping, contract `mediaPreviewSetting`); kill-and-relaunch resend verified by hand (V-SYNC-2); ROADMAP. The picker was not seen on screen. Earlier (merged #39): Remove unavailable packs: `StickerPackPort.disable` (adapter read-modify-write of `m.image_pack.rooms`), `StickerLibrary.removeUnavailablePacks`, "Remove" button, tests + contract; timeline scroll to a new last row repeats (tall photos; not re-checked on screen); ROADMAP. Earlier (merged #38): Photo captions: `TimelineViewModel.pendingPhoto/attachPhoto/removePendingPhoto`, composer strip + send in `TimelineView`, tests (`photoCaption`, contract `sendImage` with a caption); ROADMAP. Known: no auto-scroll to a tall new photo. Earlier (merged #37): Video thumbnails: `MediaAttachment.thumbnail` (domain), `TimelineMapper` (`thumbnailSource`), `TimelineRow.FileTile.thumbnail`, tile view with play overlay, test (`fileTiles`); ROADMAP. Earlier (merged #36): Media preview policy (FR-7): `MediaPreviewPolicyPort` (domain), `MatrixMediaPreviewPolicyPort` (adapter), `TimelineViewModel(previewsAllowed:)` + hidden-photo tile in `TimelineView`, `AppRoot` wiring, unit tests; ROADMAP. Earlier (merged #35): Timeline: "Jump to unread" pill (`unreadMarkerID` in `TimelineViewModel`, overlay in `TimelineView`), landing scroll repeated 4× so it reaches the first unread in a long unread run (found live), test `unreadMarker`; ROADMAP. Earlier (merged #34): Settings → Privacy → private read receipts: `AppPreferences` (FeatureSettings), toggle in `SettingsView`, `AppRoot` reads the preference, `HaloApp` applies changes via `ReadReceiptCoordinator.setPrivateReceipts`; tests (preference, runtime switch); ROADMAP. The `m.read.private` receipt as stored by the server isn't read back (AC-SET-2 server check open). Earlier (merged #33): `FeatureSettings` (new: `SettingsView`, `AcknowledgementsView`, bundled `acknowledgements.csv`, tests incl. AC-SET-1), `HaloApp` (gear button; the bare Sign out button is gone), `project.yml`/`Halo.xcodeproj`, `prepush.sh`, sync loop (an unreachable server now reports `.offline`), HANDOFF/ROADMAP. Earlier in this push (merged as #31/#32): Unavailable sticker packs (reported instead of failing the load; 2 earlier commits), sync loop re-enables send queues after a failed sync (`MatrixSessionPort`), `retrySend` re-enables the room's queue (`MatrixTimelinePort`), contract test `offlineSend` + `scripts/contract-offline-test.sh` (opt-in: stops/starts the dev Synapse), ROADMAP.

## 5. Outstanding issues
Unverified items, known limits and test notes: [docs/development/OUTSTANDING_ISSUES.md](docs/development/OUTSTANDING_ISSUES.md).

**Needs the founder** (the loop records these and moves on; AUTONOMOUS_LOOP §5)
- 📱 Device checks: G-NSE AC-NSE-1…6, V-RS-1, file protection on `halo.sqlite`, NSE database access, background push delivery.
- 👤 Gate outcomes G-UNREAD / G-FFI: evaluation written ([testing/GATE_EVALUATION_M3.md](docs/testing/GATE_EVALUATION_M3.md)); agent recommends G-FFI **pass** (stay upstream, two conditions) and G-UNREAD **stay open** until the classic-sync adapter and the S01–S22 re-run are done (V-RS-7 decided: D73) and the 📱 checks are done; push gateway, APNs keys, TestFlight.

**Deferred (not blocking):** Q-CI-MAC (D71, founder): no macOS CI job for now; `scripts/prepush.sh` stays the only Mac validation gate. Revisit once the build pipeline is stable and a hosted runner is confirmed to have the required Xcode.

## 6. Next steps
The queue is docs/ROADMAP.md §"Remaining work", worked by the loop in docs/development/AUTONOMOUS_LOOP.md. Its head:
1. **P0** the remaining client-side scenarios on the real stack (S03, S11, S12, S16–S20: restarts, outbox, NSE; most need a device), then re-evaluate G-UNREAD with the founder; measure the first-sync cost on a large account; M4 items after.

## 7. Next Session Prompt
```text
/loop Continuously execute the roadmap in a loop: **Plan → Implement → Verify**. Once a milestone is completed and verified, immediately proceed to the next milestone. Continue autonomously until roadmap finished.

Context for the loop (Halo, repository evan1ee/halo):
1. Read AGENTS.md, HANDOFF.md, then docs/development/AUTONOMOUS_LOOP.md. Trust HANDOFF for project state.
   Run scripts/install-hooks.sh once per clone.
2. The work queue is docs/ROADMAP.md §"Remaining work"; HANDOFF §6 is its head. One branch and one PR per item.
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
