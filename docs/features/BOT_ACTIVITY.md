# Feature: Bot Activity Tab

> Priority: P2 (D26) · Milestone: M7 · Modules: FeatureBotActivity, `HaloApplication/BotTaskIndexer`, HaloPersistence `BotTaskStore`, HaloBotRendering · Decisions: D18, D23, ADR-0012 · Requirement: R-P2-ACT

## 1. Purpose
One place to see tasks and reminders produced by your bots across rooms, with a link back to each source message.

## 2. User stories
- I open "Activity" and see my open bot tasks and upcoming reminders from all rooms.
- I filter by room, by bot, by status (open / pending / completed).
- I tap an item to jump to its original message; I can tick it (same protocol as in the timeline).

## 3. Task state vs Matrix messages — the core distinction
| | Matrix messages | Bot task state |
|---|---|---|
| Truth | Homeserver | **Bot backend** (D18) |
| What Halo has | The events | A **derived index** parsed from the bot's messages (`bot_task`) |
| Consequence | Exact | Possibly stale/incomplete: Halo only knows what it has seen in timelines |

The tab must therefore **label freshness**: each item shows "as of <time of the latest bot message about it>", and the list header says
"From messages on this device". The index never invents state: completion is set only from bot messages (BOT_MESSAGES §6 confirmation rules).

## 4. Functional requirements
- FR-1 `BotTaskIndexer` consumes timeline events of allowlisted bots from rooms as they are synced or paginated (no extra network) and updates `bot_task` idempotently:
  `TaskAddedV1` → upsert (open, source event); `TodoListV1` rows → update title/status for known ids, and upsert rows for **unknown** ids without a source event (`source_event_id` NULL → read-only, "Not available" for ticking, D23); completion confirmations → completed; delete confirmations → deleted; edits → re-parse; redactions of the source → mark `source_redacted`.
- FR-2 Optional "Refresh from bot" button sends the bot's list command as a visible message (**only with explicit user action**; D18 says no hidden commands) — **[OPEN Q-ACT-REFRESH]**: confirm whether this is wanted (it's a visible text command, which D22 avoids for checkboxes).
- FR-3 Sections: Open, Pending (local action in progress), Reminders (by time), Completed (last 7 days).
- FR-4 Item actions: open source message, tick (BOT_MESSAGES FR-3), copy.
- FR-5 Index lifetime: rebuilt on demand from cached timelines ("Rebuild index"); entries untouched for 90 days are pruned.

### Built so far (M7 slice, 2026-11-21)
- **FR-1 (partly):** `BotTaskDerivation` (HaloDomain, pure) reads one room's bot messages oldest first and derives the entries (`TaskAddedV1`, `TodoListV1` rows incl. unknown ids without a source, `ReminderSetV1`, completion and deletion by unique title, reused ids restart open); `BotActivityCoordinator` (HaloApplication) receives every snapshot of an open timeline from `TimelineViewModel` and upserts them (`BotTaskPort` → `BotTaskStore`, monotonic by `as_of`, a missing source keeps the stored one). Because the whole list is re-read each time, the same timeline always gives the same entries (AC-A3). Only rooms **opened on this device** are indexed (no sync-time indexing); edits are read as they are now (the timeline hands over the edited body); a deleted source message marks the entry (`source_redacted`): no tick, no jump, "Its message was deleted".
- **FR-3:** sections Open, Reminders, Completed this week (7 days); "Pending" doesn't exist yet (no `BotActionCoordinator`). Filters by room and bot (FR in §2; status filter is the sections).
- **FR-4 (partly):** tap opens the room at the source message when it has one (loads up to 10 pages of history to reach it, then scrolls and tints it; a task seen only in a list just opens the room), Copy in the context menu; **ticking from the tab is built** (`BotActionCoordinator`, HaloApplication): a circle on open tasks that have a source message (never on list-only tasks or reminders) sends one 👍 on the creating message (`TimelineSession.addReaction`, idempotent: never removes an existing one, works for events outside the loaded window), shows a spinner and "Waiting for bot…" while a short-lived timeline of the room stays open and feeds the index, and the task moves to Completed only when the bot confirms (a newer list or `Marked task as done`); after 2 minutes without it the row says "No response from bot. Tap to try again."; a failed send says so. Pending state is in memory only (the `bot_action` table is not built): after a restart the task shows open again and a second tick is safe.
- **FR-5:** "Rebuild list" empties the index; entries whose newest bot message is older than 90 days are dropped when the account is attached (`BotActivityCoordinator.retention`).
- **FR-2:** not built (Q-ACT-REFRESH stays at its default: no).
- Header text says "From messages on this device". Entry point: a checklist button in the room list toolbar, shown once the user has allowlisted a bot (Settings → Bots); the screen is a sheet (`FeatureBotActivity`), not a tab.

## 5. Non-functional requirements
The index adds ≤ 1 ms per bot event; the tab opens from the DB in < 200 ms.

## 6. User flows
Tab → list → tap → timeline at the event (event-focused timeline, F-FFI-22) → back.

## 7. State transitions
`bot_task.status`: `open → pending(local) → completed | deleted`; `pending` lives in `BotActionCoordinator` (memory + `bot_action` table for crash safety), not in the index's status.

## 8. Data models
See [../data/DATA_MODELS.md](../data/DATA_MODELS.md) `bot_task`, `bot_action`.

## 8b. API boundaries
FeatureBotActivity → `BotActivityUseCase` (HaloApplication) → `BotTaskStore` (port, HaloPersistence) for reads; ticks go through `BotActionCoordinator` → `TimelinePort` (same as BOT_MESSAGES §8). The indexer receives bot events from `TimelinePort` sessions and sync-time room updates via the adapter; it never calls the network itself.

## 9. Error scenarios
The source room left → items marked "room left" and hidden by default · the bot changed format → index stops updating (diagnostics count unparsed bot messages).

## 10. Edge cases
Tasks created before Halo was installed (only known after paginating back or a new list) · several bots with the same templates (the key includes the sender) · two Halo devices (each builds its own index; the bot is the truth).

## 11. Acceptance criteria
- AC-A1 Every open task visible in the latest bot list in any room appears in the tab after that list was synced.
- AC-A2 Completion in the tab follows AC-B2 exactly.
- AC-A3 Deleting the index and rebuilding gives the same result from the same cached timelines (determinism).

## 12. Test requirements
Unit: indexer as a pure reducer over event sequences (shuffled, duplicated, with edits/redactions) → same final index. Integration: S-ACT-1 with the scripted fake bot.

## 13. Open questions
Q-ACT-REFRESH.
