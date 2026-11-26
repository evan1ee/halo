# Motion audit (ROADMAP M19-9, AC-MOT-1)

`scripts/motion_audit.py` films the simulator while `HaloUITests.testMotionAudit` plays one transition (scenarios: `launch`,
`room-open-close`, `keyboard`, `send`, `reaction`, `appearance`, `background`, `scroll-up`), asks ffmpeg for the difference between
neighbouring frames at 30 fps, and writes a strip of frames per burst of change (`build/motion-audit/<scenario>-burst-N.png`, read
left to right, top to bottom) and a table of burst lengths. It needs the signed-in `Halo Perf` simulator (`scripts/perf.py` makes it)
and the scale server (`infra/dev/scale-fixtures.py up`). The strips are read by eye; nothing here is pass/fail yet.

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

## D-MOT-2 fix: view models started ahead (2026-11-26, simulator)
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
- **Not covered:** a room outside the top three still opens as before (≈ 0.23 s re-open, 0.4–0.7 s first open); touch-down warming of the
  tapped row was not built. Each waiting model holds a live SDK timeline (three at most, on top of the adapter's six prepared ones).

## To do
1. Rooms outside the top three: start a model on touch-down of a row, or cut the first-open build of the screen (205 ms) and the serial reads (150 ms).
2. Make the window exact: have the test draw a marker the film can find (for example a one-frame colour flash in a corner at each mark), then read the strips of send, reaction, scroll up, room close and the two appearance flips.
3. Scenarios for edit, reconnect and history prepend.
4. Turn what can be measured into UI tests (for example: no frame with an empty message area after a warm push, from the film's frame differences).
