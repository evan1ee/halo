# Motion audit (ROADMAP M19-9, AC-MOT-1)

`scripts/motion_audit.py` films the simulator while `HaloUITests.testMotionAudit` plays one transition (scenarios: `launch`,
`room-open-close`, `keyboard`, `send`, `reaction`, `appearance`, `background`, `scroll-up`), asks ffmpeg for the difference between
neighbouring frames at 30 fps, and writes a strip of frames per burst of change (`build/motion-audit/<scenario>-burst-N.png`, read
left to right, top to bottom) and a table of burst lengths. It needs the signed-in `Halo Perf` simulator (`scripts/perf.py` makes it)
and the scale server (`infra/dev/scale-fixtures.py up`). The strips are read by eye; nothing here is pass/fail yet.

## Result of the first pass (2026-11-26, simulator)

| Transition | Looked at | Result |
|---|---|---|
| Room open | strip of the push | **Defect D-MOT-1:** the pushed screen shows the composer and an empty white message area for about 7 frames (0.23 s) before the rows appear, although the messages are on the device. The list is hidden (`opacity 0`) until it has landed at the newest message (D95); M19-4 cut the wait but not the blank. |
| Keyboard up | strip | Good: the messages and composer ride up with the keyboard; no row jumps. |
| Return from background | strip | Good: the system's zoom shows the room with its content from the first frame. |
| Room close, scroll up, reaction | bursts listed, strips made | Not read yet. |
| Send → confirm | strip | Not valid: `typeText` types three characters and the software keyboard drops (the simulator's keyboard setting, see `prepush.sh`); the test needs the same setup before it films a send. |
| Appearance change | burst list | No burst in the scenario window: either the switch isn't seen by the film or the app doesn't change; check by hand. |
| Launch | burst list | The launch sits before the window's first mark; move the mark. |
| Edit, reconnect, history prepend | — | No scenario yet. |

## To do
1. Fix D-MOT-1: show rows from the first frame when the list already opens at the bottom (`defaultScrollAnchor`), keeping D95 (no frame of the room's top).
2. Read the remaining strips; add scenarios for edit, reconnect and history prepend; fix `send`, `appearance` and `launch`.
3. Turn what can be measured into UI tests (for example: no frame with an empty message area after the push, using the film's frame differences).
