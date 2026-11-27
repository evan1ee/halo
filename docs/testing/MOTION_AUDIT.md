# Motion audit (ROADMAP M19-9, AC-MOT-1)

`scripts/motion_audit.py` films the simulator while `HaloUITests.testMotionAudit` plays one transition (scenarios: `launch`,
`room-open-close`, `room-open-other` (the fifth chat, outside the rooms started ahead), `keyboard`, `send`, `reaction`, `edit`, `appearance`, `background`, `scroll-up`, `history-prepend`, `reconnect`), asks ffmpeg for the difference between
neighbouring frames at 30 fps, and writes a strip of frames per burst of change (`build/motion-audit/<scenario>-burst-N.png`, read
left to right, top to bottom) and a table of burst lengths and flat-blank frame counts. `--assert` fails on any test failure or blank frame in a no-blank transition. It needs the signed-in `Halo Perf` simulator (`scripts/perf.py` makes it)
and the scale server (`infra/dev/scale-fixtures.py up`).

## Result of the first pass (2026-11-26, simulator)

| Transition | Looked at | Result |
|---|---|---|
| Room open | strip of the push | **Defect D-MOT-1 (partly fixed, see below):** the pushed screen shows the composer and an empty white message area for about 7 frames (0.23 s) before the rows appear, although the messages are on the device. The list is hidden (`opacity 0`) until it has landed at the newest message (D95); M19-4 cut the wait but not the blank. |
| Keyboard up | strip | Good: the messages and composer ride up with the keyboard; no row jumps. |
| Return from background | strip | Good: the system's zoom shows the room with its content from the first frame. |
| Room close, scroll up, reaction | bursts listed, strips made | Not read yet. |
| Send → confirm | strip | Not valid: `typeText` types three characters and the software keyboard drops (the simulator's keyboard setting, see `prepush.sh`); the test needs the same setup before it films a send. |
| Appearance change | burst list | No burst in the scenario window: either the switch isn't seen by the film or the app doesn't change; check by hand. |
| Launch | burst list | The launch sits before the window's first mark; move the mark. |
| Edit, reconnect, history prepend | — | No scenario yet. |

## D-MOT-1 after the fix (2026-11-26)
A list that appears with its messages already known (`model.landed`), no more than 40 rows and not focused, is drawn at once (`TimelineView.startsPlaced`, `revealedAtOnce`); the gate until the landing scroll stays for the rest. Film of `room-open-close` on the simulator: the empty area went from about 7 frames to about 3, and the rows appear already at the newest message, without a jump. The D95 check (10 opens) still passes. What is left is the time before the rows exist at all (the view model is `.opening` while the timeline loads), about 0.1 s.

## Second pass (2026-11-26)
- **Cold room open — defect D-MOT-2:** the first room opened after a launch shows an empty message area (composer visible, no rows) for about 11 frames (0.4 s) while the timeline loads from the store, although the messages are on the device. AC-MOT-1 asks for no such frame. A fix has to put rows on screen without waiting for the SDK timeline (last known rows from Halo's own store, or a warm view model started when the chat list shows the row).
- **Launch** now lands on the chat list (the founder's rule); the film shows the list's skeleton rows for a moment before the rows, by design (M13) but also content already on the device: filed with D-MOT-2.
- **Appearance:** the runner's own `XCUIDevice.appearance` did not change the film; the script now switches the simulator (`simctl ui … appearance`) on the test's "dark" / "light" marks. The flips were filmed; their strips are not read yet.
- **Send, reaction, scroll up, room close:** filmed; the scenario window is still approximate (the test's begin and end marks are matched to the film by the recorder's first frame, off by a second or so), so the strips after the room open show the end of the test (a blank screen when the app is closed), not the action. Typing now works (software keyboard setting, as `prepush.sh`).

## D-MOT-2 analysis (2026-11-26, simulator, timings written from the code path)
- The data is fast: from `TimelineViewModel.start` to the first snapshot with rows takes 5–45 ms, warm or not (the event cache serves the first page at once, `firstPage` returns in ~0 ms). Before it: route change → `start` 40 ms on a re-open, **205 ms on the first open after a launch** (building the screen); `start` → `coordinator.open()` 40 ms re-open, 150 ms first open (the draft, read position and preview-setting reads are awaited one after another before the timeline opens).
- The film (optimised build, as `scripts/perf.py`) still shows about 7 empty frames (0.23 s) on a re-open and 0.4–0.7 s on the first open: the page slides in with the composer while the message area waits for the view model to open its timeline and the list to lay out 35 rows.
- Tried and dropped: opening the timeline while the two reads run (a reorder of `start`). One `scripts/perf.py` run gave NFR-11 p95 0.315 s against 0.238 s before; the simulator differs by up to 28 % between runs, so it was not kept without a gain it could show, and the unread marker depends on the read position being known first.
- What would remove the empty frames: a view model that is already started when the screen is pushed (created and started when the chat list shows the row, or on touch-down), so its first frame has rows. It needs care for read state: a started but not visible model must report nothing (`isActive` is false until it appears).

## D-MOT-2 fix: view models started ahead (2026-11-26, simulator; retired by D126, see the last section)
- **Built:** `WarmTimelines` (FeatureTimeline) keeps a started `TimelineViewModel` for each of the top three rooms of the chat list (after
  `MatrixTimelinePort.warm` has prepared their SDK timelines); `AppRoot.makeRoomTimeline` hands it to the pushed `TimelineScreen` (a room opened
  at a message always gets a new one). The cache follows the top of the list, never prepares a room that is on screen, prepares a closed room
  again 0.6 s after it closed, replaces a waiting model whose screen closed without it (opened at a message), and lets go of everything on
  sign-out (`resetAccountState`) and on a memory warning.
- **Read state:** a model started with `startAhead()` has `isPresented == false` and reports nothing: no read receipt or seen event
  (`reevaluateSeen` treats it as inactive), no own message as read (`reportOwnMessage`), no `m.marked_unread` clearing; the draft is only read
  (restoring it writes nothing and sends no typing notice). `TimelineView.onAppear` calls `present()`: it lands at the newest row (D95),
  reports what a fresh open would, and reads the read position and the preview setting again (the unread marker follows the position of that
  moment). Tested in `WarmTimelinesTests` (a mutation that lets `reportOwnMessage` run while hidden fails it).
- **Film (`room-open-close`, optimised build):** before, the re-open showed the composer over an empty message area for 6 frames; after, the
  first open after a launch and the re-open both slide in with their rows on the first frame (0 empty frames), at the newest message, without a
  jump. The re-open fell just after the script's window (it is still approximate) and was cut from the film by hand
  (`ffmpeg -ss … -vf fps=30,tile`). D95 check (`testRoomOpeningLandsAtNewestTenTimes`, 10 opens on `Halo Perf`) passed.
- **Not covered:** a room outside the top three still opens as before. Film of `room-open-other` (fifth chat, simulator): the first open
  shows the empty message area for 7–9 frames, a re-open for about 2. Each waiting model holds a live SDK timeline (three at most, on top
  of the adapter's six prepared ones).
- **Tried and dropped: starting the model on touch-down of a row.** A `simultaneousGesture(LongPressGesture(minimumDuration: 0))` on the
  row swallowed the row's tap in the `List` (the film showed no room opening while the UI test still passed: the scenario now asserts
  that the room opened). It also cannot win much: a list's scroll view holds back a quick tap's touch-began until the finger lifts, so
  "touch-down" arrives about when the tap does. A custom `ButtonStyle` reading `isPressed` would have the same delay and lose the row
  highlight. What it uncovered was kept: a model handed out by the cache is held back from the moment it is made (not only once its
  start runs), `start()` waits for a start already under way instead of opening the timeline twice, and a start ahead that runs after
  the screen appeared doesn't hide it again (`WarmTimelinesTests`, checked by mutation).

## Where a room outside the top three loses its time (2026-11-26, simulator, optimised build)
Measured with a temporary `os.Logger` probe in `TimelineViewModel.start()` (not kept) while filming `room-open-other`, the fifth chat:

| Open | model created → `start()` runs | read position + preview setting | `coordinator.open()` | first rows after `start()` |
|---|---|---|---|---|
| first after a launch | 313–385 ms | 6–9 ms | ≤ 1 ms | ≈ 10 ms |
| re-open | 46–49 ms | 5–6 ms | 5–13 ms | ≈ 10 ms |

- **The serial reads are not the cost any more:** reading the read position and the preview setting takes under 10 ms together (the
  150 ms in the analysis above came from an earlier build). Overlapping them with the timeline's open would save at most that.
- **The cost is the first build of the room screen.** `TimelineScreen.init` makes the model; its `start()` only runs from the screen's
  `.task` 313–385 ms later on a first open, because the main actor is busy building and laying out the screen meanwhile.
- **Tried and dropped: starting the model as the screen is built** (in `TimelineScreen.init`, through the cache so a rebuilt screen
  gets the same model). The probe still showed the start 352 ms after the model was made: a `Task` queued on the busy main actor
  waits for the screen build like everything else. The film went from 7–9 to about 6 empty frames on the first open, within noise, so it
  was not kept.
- A `sample` of the app from launch through the first open puts almost none of the main thread's time in Halo's own frames (row
  bodies, `TimelineView.body`, `ComposerPanelArea.body` a few ms each); the rest is SwiftUI and UIKit building the screen. `xctrace`
  could not symbolicate a simulator trace against a `dsymutil` dSYM ("no dSYMs relevant"). Next: profile the first room open in
  Instruments with the SwiftUI template (or on the iPhone 📱) to see which views cost the 300 ms, or keep more rooms started ahead.

## The first room screen of a launch: profiled; building it ahead tried and not kept (2026-11-26, simulator, optimised build)
- **It is a once-per-launch cost, not a per-room one:** model made → `start()` for the fifth chat was 191–385 ms when it was the first room
  screen of the launch, 73 ms when a top room had been opened before it, 46–58 ms on a re-open.
- **Profile** (Time Profiler launched by `xctrace` with `HALO_MOTION_ATTACH=1`, so the motion test drives the running app; simulator
  frames symbolicated with `atos -p` against a live Halo process of the same simulator boot; Instruments' SwiftUI instrument recorded
  nothing on the simulator, attached or launched): of the 710 ms of main-thread time around the first open, about 95 ms is XCUITest's own
  accessibility snapshots (a test artefact), 178 ms the Swift runtime's first protocol-conformance lookups
  (`swift_conformsToProtocolMaybeInstantiateSuperclasses`; 73 ms of them from SwiftUI scanning each new view type for dynamic
  properties, `DynamicPropertyCache.fields`, about 33 ms from resolving `some View` types), about 146 ms the list creating its first cells
  and 126 ms the navigation stack making the pushed hosting controller. Halo's own code (row bodies, `TimelineView.body`) is a few ms.
- **Tried and not kept:** `TimelineWarmUpView` (FeatureTimeline) is the room screen with sample rows, a model that belongs to no room (no receipts,
  no drafts, a port that opens nothing) and none of the room's lifecycle (`TimelineView.isWarmUp`: no start, no present, no active state,
  no stop). `RootView` puts it behind the chat list, transparent and hidden from accessibility, from 1 s to 2 s after the list first
  loads, once per launch. Built off the window (offset) it gained nothing: the list inside made no cells.
- **What it gained:** model made → `start()` on the fifth chat's first open 111–115 ms in three runs (191–385 ms before); the film showed
  about 4 empty frames on that open (7–9 before) and no frame change while the warm-up was built.
- **Why it was removed:** `testLaunchShowsChatsNotTheLastRoom` found a `sticker-button` right after launch: the hidden composer stayed
  in the accessibility tree despite `.accessibilityHidden(true)` (so VoiceOver could likely reach it for that second); and
  `scripts/perf.py --accounts scale300` gave NFR-11 p95 0.567 s against 0.206–0.222 s for the same code without it, as opens during the
  warm-up wait for its ≈ 300 ms of main-thread work. A future attempt needs an accessibility-proof host and a time no open can meet.

## Rooms started on the tap, top-three models retired (2026-11-26/27, simulator, optimised build, D126)
**How it was measured:** `scripts/room_open_bench.py` (`HaloPerformanceTests.test6RoomOpenSequence`) launches the app afresh in each
round, lets it settle 4 s, then opens the fifth chat (the first room screen of the launch), the same chat again, the sixth chat and the
first chat, and reads two signposts from the simulator's log: `room-first-rows` (tap → the list first draws rows; the message area stops
being empty) and `room-open` (tap → placed at the newest message, NFR-11). Both now begin at the tap, not when the room reaches the
navigation path. Five rounds each; median (range), ms. The simulator varies up to 28 % between runs; the phone is still to do 📱.

| Build | first room of the launch | re-open | new room, not the first | top room |
|---|---|---|---|---|
| before (top three started ahead) | 312 (292–1111) | 89 (88–438) | 77 (77–273) | 32 (32–100) |
| + the tapped room starts before its push | 251 (229–365) | 84 (52–254) | 48 (32–60) | 34 (33–158) |
| + the first room screen built once, hidden (not kept, see below) | 91 (71–107) | 53 (45–75) | 38 (37–112) | 40 (31–50) |
| + top-three models retired, with that screen | 65 (61–830¹) | 49 (42–62) | 35 (32–40) | 35 (31–41) |
| **kept:** started on the tap, top-three retired, no hidden screen | 236 (180–318) | 46 (43–79) | 36 (35–55) | 35 (33–88) |

¹ the first launch after installing the build. `room-open` (placed at the newest message) medians: 195–199 ms for the later opens,
554 ms for the first of a launch (before: 201–563 ms); it includes the landing check, which waits for the rows to settle at the bottom.
`scripts/perf.py --accounts scale300`, the same evening on the same simulator: NFR-11 p95 0.44 s for the kept build, 0.423 s for
`7291be2` (top three started ahead): equal within the simulator's noise (the 0.206–0.222 s recorded earlier came from a quicker state
of the simulator; idle CPU was higher in both of these runs too).

- **Where the time was:** the data was never the cost (reads < 10 ms, first rows ≈ 10 ms after `start()`). Without a model ready, the
  screen was pushed with an empty message area and the rows came 2–9 frames later; the first room screen of a launch also paid a
  once-per-process ~230 ms of SwiftUI and Swift-runtime setup (the bench: 312 ms against 77 ms for a later new room; a Time Profiler
  pass by the parallel session put most of it in the runtime's first protocol-conformance lookups and the list's first cells, almost
  none in Halo's own view code).
- **Start on the tap (`PreparedTimelines`, `AppRoot.openWhenReady`):** the tap starts the room's view model (held back, it reports
  nothing) and pushes the screen when the model has landed (`TimelineViewModel.canShow`), or after 150 ms (a slow or empty room is
  pushed as before and shows its rows when they come). A second tap before the push replaces the first, whose timeline closes.
- **First screen built once (`TimelineWarmUpView`), measured and not kept:** the parallel session had built and removed it (its section
  above): its composer stayed in the accessibility tree despite `.accessibilityHidden`, and opens that fall in its second wait for its
  ≈ 300 ms of work (NFR-11 p95 0.567 s). This bench waits 4 s after launch, so it missed the second. Without it, the first room of a
  launch is pushed ~200 ms later, with its rows: the film shows no empty frame, the slide just starts later.
- **Retired:** the three view models kept started for the top of the chat list (three live SDK timelines and their mapping on every
  change). A room started on the tap now opens as fast; the adapter still keeps the top rooms' SDK timelines ready.
- **Film (`motion_audit.py room-open-other room-open-close`, kept build):** the fifth chat (first room of the launch, outside the old
  top three) slides in with its rows on the push's first frame and they don't move (was 7–9 empty frames); the first chat the same. Left: on the
  first chat, the newest own messages at the very bottom appear about two frames after the rest, without a jump.
- **Measured and not changed:** `RowView` made `Equatable` (so a list pass could skip unchanged rows): a probe counted 440 row bodies
  over 12 opens without it and 453 with it, about one per visible row per open, so SwiftUI already skips unchanged rows here; not kept.
  Scrolling was not probed.
- **Media:** the thumbnail memory a row paints from on its first frame was one per view model, so a re-opened room started empty and
  showed placeholders until its pictures came back from the loader; one store now serves every timeline (32 MB, cleared on a memory
  warning and on sign-out). Not filmed: the scale accounts' rooms have no photos.

### Against Element X's room opening (the founder's investigation report, 2026-11-26)
| Area | Halo now | Verdict |
|---|---|---|
| Chrome, timeline and composer state apart | One `TimelineViewModel`; rows read only narrow model state (pins, preview setting), tracked per row by Observation | Not split: the probe shows no excess row work on open; revisit only with a measured cost (typing, keyboard) |
| Subscribe before the screen mounts | Built: the tap starts the timeline, the push waits for its rows (bounded) | Adopted, with Halo's cancellation (a newer tap wins, the old timeline closes) |
| Virtualised list (`UITableView`, diffable, inverted) | SwiftUI `List` (a collection view underneath, cells only for visible rows), opened at the bottom with `defaultScrollAnchor` | Not adopted: the cost was never the list's rows (Halo's own view code is a few ms of the open) |
| Presentation built off the main actor | Mapping on the main actor, rows reused per item (M19-2); the first snapshot maps in ≈ 10 ms | Not now: no measured open cost; M19-2's open items stay |
| Per-row observation and equality checks | Rows take value rows; Observation per row | Measured (above), nothing to gain on open |
| Heavy composer panels mounted lazily | Panels are built when shown (`ComposerPanelArea`) | Already so |
| Media frames, memory fast path, cancellation | Frames from the event's size, BlurHash, decoded-image cache read in `init`, `.task` loads cancelled with the row, loader de-duplicates | Already so; the shared thumbnail memory added |
| Visible-room sliding-sync subscriptions | Classic sync (D73/D125): every joined room's events arrive anyway; the adapter prepares the top rooms' SDK timelines | Not applicable |
| Cache of recent rows across visits | None | Not built: rows are on the device within ms of the tap; a second copy of timeline state would need reconciling for edits, redactions and decryption (AGENTS §4.1) |

## Third pass — exact window, all 12 transitions, and D-MOT-3 fix (2026-11-27, simulator, optimised build)
- **Exact window calibration:** `testMotionAudit` emits `mark("calibrate")` immediately after `mark("end")` while Halo is still open in light mode, and waits for a `"calibrated"` handshake written by `motion_audit.py` after its `dark` (0.35 s) → `light` pulse (global brightness step 157–237, detected via `CALIBRATION_STEP = 140.0`, distinct from the ~120 Home Screen teardown step). `motion_audit.py` also checks per-frame central-region luma range (`blank_flags`) and supports `--assert`.
- **New scenarios:** added `edit` (send → long-press → Edit → revise → send), `history-prepend` (scroll to top → back-paginate older messages), and `reconnect` (chat list → `docker pause halo-scale-synapse-1` until `"Offline — waiting to reconnect"` appears → `docker unpause` until banner clears). Fixed `send`/`edit` simulator text input (clipboard paste fallback) and `reaction` target selection (visible hittable message bubble in viewport).
- **Defect D-MOT-3 (found in `history-prepend`, fixed with SwiftUI `List` residual):**
  - *Before:* when back-pagination prepended earlier events on the same day, `PrependedAnchor` watched `rows.first?.id` — which was a synthetic `.dateDivider` (`Wednesday`) that `matrix-rust-sdk` deletes and recreates at the top. `PrependedAnchor.anchor` returned `nil`, so SwiftUI `List` teleported ~50 rows up to `"This is the start of the conversation."` / join events.
  - *Fix:* `PrependedAnchor.firstStableID(in:)` (`FeatureTimeline/TimelineScrollHelpers.swift`) skips synthetic `.divider`, `.marker`, timeline-start, and collapsible settings rows so the anchor is always the prior oldest real event row; `TimelineView` re-anchors without animation (`withTransaction`, `disablesAnimations = true`) synchronously and on short follow-up layout passes (cancelled immediately on user touch). Covered by `PrependedAnchorTests.skipsVirtualDividersWhenSameDayEventsPrepend`.
  - *After (`history-prepend-burst-2.png`, `dbg-prepend-after.png`):* the prior oldest message (`away 0`) stays visible on screen instead of teleporting to room creation (0 blank frames, no bounce-back). Residual: `away 0` shifts down by ~1 viewport height on the prepend frame because SwiftUI `List` estimates heights for newly inserted multi-line rows above it.
- **Measurable UI test:** added `HaloUITests.testRoomOpenShowsRowsAtNewestWithoutSpinner` (verifies warm open, re-open, and 5th-room open render `timeline` with no loading spinner and no `jump-to-bottom`, D95 / AC-MOT-1).

| Transition | Scenario | Strips inspected | Result |
|---|---|---|---|
| Launch → chat list | `launch` | Yes | White launch screen (~0.66 s) → structured skeleton (2 frames, 67 ms) → chat list in 1 crisp swap; 0 flicker, 0 jump. |
| Room open (top room, warm & re-open) | `room-open-close` | Yes | Rows visible on frame 1 of push; 0 blank frames, 0 jumps (D126). |
| Room open (5th room, outside top 3) | `room-open-other` | Yes | Rows visible on frame 1 of push on first open and re-open; 0 blank frames, 0 jumps (D126). |
| Room close → chat list | `room-open-close`, `room-open-other` | Yes | Smooth pop back to chat list; 0 blank frames, 0 jumps. |
| Keyboard up & down | `keyboard` | Yes | Composer and messages ride smoothly with keyboard both ways; 0 blank frames, 0 jumps. |
| Send → confirm | `send` | Yes | Bubble enters cleanly at bottom and transitions sending → confirmed check in place; 0 blank frames, 0 jumps. |
| Reaction (double-tap 👍) | `reaction` | Yes | `👍 1` chip appears in place under the tapped message; 0 blank frames, 0 scroll jumps. |
| Edit message | `edit` | Yes | Action sheet slides cleanly → Edit loads composer + banner without jump → Send updates bubble in place with `(edited)`; 0 blank frames. |
| Appearance (light ↔ dark) | `appearance` | Yes | Instant 1-frame flip both directions (step 236.6); 0 intermediate frames, 0 flicker, 0 jump. |
| Return from background | `background` | Yes | System zoom shows room content from frame 1; 0 blank frames, 0 jumps. |
| Scroll up | `scroll-up` | Yes | Smooth scroll through history; 0 blank frames. |
| History prepend | `history-prepend` | Yes | **D-MOT-3 fixed (with SwiftUI `List` residual):** no longer teleports ~50 rows to room start; prior oldest row stays on screen with ~1-viewport shift from estimated heights of newly prepended multi-line rows; 0 blank frames. |
| Offline → reconnect | `reconnect` | Yes | `"Offline — waiting to reconnect"` banner appears and clears cleanly in 1 crisp frame on the chat list; 0 blank frames, 0 flicker. |

## Remaining device-only / follow-up items
1. **Physical iPhone 📱:** measure room open (`scripts/room_open_bench.py` needs a simulator; measure on iPhone 16) and film a re-opened room containing photos (the scale accounts have text-only rooms).
2. **Once-per-launch first-room setup:** ~200 ms between tap and push on the first room screen of a launch (SwiftUI/runtime setup; hidden warm-up tried twice and not kept).
3. **D-MOT-3 SwiftUI `List` residual:** ~1-viewport height shift on history prepend when multi-line messages prepend above the reader; revisit only if SwiftUI `List` is replaced by a custom scroll container.
