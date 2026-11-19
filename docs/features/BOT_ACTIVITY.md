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

## 5. Non-functional requirements
The index adds ≤ 1 ms per bot event; the tab opens from the DB in < 200 ms.

## 6. User flows
Tab → list → tap → timeline at the event (event-focused timeline, V-TL-1) → back.

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
