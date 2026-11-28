# Feature: Message Search

> Priority: P2 · Milestone: M8 (SDK index) → M19-11 (own index, **built**; not checked on an iPhone) · Owner modules: FeatureSearch, HaloApplication, HaloDomain, HaloMatrixAdapter, HaloPersistence · Requirements: R-P2-SEARCH

Decisions: D30, D123, D124, ADR-0024. Built with M19-11 (2026-11-25), tested on the simulator and against real servers; not yet on an iPhone (§12, 📱).

## 1. Purpose
Find any message this device can read, **in encrypted and unencrypted rooms, back to the start of each room**, on the device.

## 2. User stories
- I find a message in an encrypted chat by a word I remember, however old it is.
- I find a Chinese, Japanese or Korean word inside a sentence, also mixed with Latin text.
- I find a file by its name or a link by its address.
- I see how far back the search reaches, and that it isn't complete yet.
- After I enter my recovery key, older encrypted messages become searchable without doing anything.

## 3. Functional requirements
- FR-1 **Encrypted rooms.** Messages are indexed on the device after the SDK decrypted them. Nothing is sent to the server to search: no query, no word, no hash. `POST /search` is never used, for unencrypted rooms either (one behaviour).
- FR-2 **What is searchable in an encrypted room:** every message this device has the key for: received since sign-in, from key backup after verification or recovery, or shared with the device. A message without a key is not searchable; it is recorded (event ID only) and indexed when its key arrives.
- FR-3 **Depth:** full history (D123), until each room's start or the point the server stops giving history.
- FR-4 **Content:** text, notice and emote bodies (Markdown source and reply fallback stripped), captions, file names, link addresses, sender names, poll questions and options (a poll that arrives live only in the 200 most recent rooms; elsewhere when the room is read). A gallery is one result, found by each of its file names. Not: reactions, state events, media contents, locations' coordinates.
- FR-5 **Languages:** normalised (NFKC), case and diacritics ignored. Runs of CJK characters are split into characters on writing and matched as a **phrase** on reading; Latin words match by prefix. One tokeniser for index, query and highlighting. Scripts without spaces that aren't CJK (Thai, Lao, Khmer) match by prefix of the whole run only.
- FR-6 **Query safety:** user text never reaches FTS5 as syntax; tokens are quoted; a query without any token returns no results and no error.
- FR-7 **Order and paging:** newest first, paged by (time, row). No relevance ranking.
- FR-8 **Filters:** room (used by M20-11: in-room search bar from the room toolbar `⌘F` and Room Info, using an independent room-scoped `SearchCoordinator` with previous/older `↑` and next/newer `↓` stepping across pages, per-room indexing/offline/empty/error notices, thread-match handoff, and M20-1 focused jumps without affecting read state — **built** 2026-11-28) and kind: messages, media, files, links.
- FR-9 **Live lane:** the SDK's per-room listeners (message, encrypted, redaction; poll start in the 200 most recent rooms) deliver what sync brings, decrypted; edits and deletions are applied; undecryptable ones are kept by ID and asked for again after a minute, then at doubling intervals up to half a day, and at once when a key backup is connected. Listeners are registered before the first sync of a run, which waits for that at most 1.5 s.
  **Missed messages:** after the first response of a run or an interruption every touched room, and later any room with five or more messages in one response, is compared with the server: the IDs of its 30 newest messages (one request). An unknown one is a gap, read back until known messages are reached. (Counting the events of a response isn't enough: reactions can fill it, ADR-0024.)
- FR-10 **History lane:** starts by itself when sync is quiet; most recent rooms first (or `SearchQuery.room` first during an active room-scoped search); one room at a time, in slices; stores its position after each slice; runs in an SDK client of its own that is dropped about every 20 rooms or 5,000 events (ADR-0024); stops for Low Power Mode, thermal state serious or worse, mobile data (setting, default off), offline, server errors (waits 5 s to 5 min) and for 3 s after the person opens a chat (`noteActivity`); rests as long as it reads during passive sweeps, and paces lightly without launch/idle waits while fulfilling an active search so remote history streams in progressively; goes on in a processing task on the charger.
- FR-11 **Instant local results, progressive remote re-check:** local index hits (`searchLocal`) are returned and displayed immediately on every keystroke without waiting on network calls. Once typing pauses (`150 ms`), hits not checked within the last hour are asked of the **server** in the background (`recheck` via `GET /event`, not the SDK's cache: a deletion inside a part of the room that sync left out never reaches it). A deleted one is removed from the index and the displayed results in place, and an edited one updates to its new text without losing paginated pages. Direct `search` waits at most 1.2 s for the answers; what is unanswered then (offline) is shown as the index has it. Ignored senders and rooms that aren't joined are left out (cached in memory so keystrokes make no FFI hops).
- FR-12 **Opening a hit** goes to the event, in its thread if it is in one, through M20-1. Gone or not reachable is said.
- FR-13 **Coverage notice:** "Searched back to <month> · n of m chats complete" ("Reading your chats" while a chat hasn't been read at all), why it waits, and how many messages can't be decrypted, with a way to verification when the device isn't verified. Nothing is shown once all is searchable.
- FR-14 **Settings → Message search:** progress, size and number of messages, pause, mobile data, delete and rebuild.

## 4. Non-functional requirements
NFR-14 and NFR-15 hold with the index on: at 1,000 rooms first sync ≤ 60 s, catch-up ≤ 10 s, ≤ 1 s CPU per idle minute once the history lane is done or paused, ≤ 20 MB extra memory (simulator, TEST_STRATEGY §7).
First results ≤ 200 ms p95 at 300,000 messages (simulator: ≤ 52 ms). NFR-4: no message text, file name, address or query in logs. Protection at rest: [../security/SECURITY.md](../security/SECURITY.md) §4.

## 5. User flows
Pull down on the chat list → type → matching chats and conversation-style message hits (52 pt room avatar, room title, Messages-style relative date, `<sender>: <highlighted snippet>` or an inline attachment card with thumbnail and `FORMAT (SIZE)` subtitle) → tap a hit → the room or thread at that message. Scrolling dismisses the keyboard interactively.
First use on a large account: results appear at once for what is indexed, with the coverage notice.

## 6. State transitions
Room coverage: `none → partial(oldest event) → complete`, or `blocked` when the server doesn't give the history (counts as complete).
Indexer: `indexing`, `paused(reason)`, `done`, `unavailable` (locked), `stopped` (signed out). The live lane runs in all but the last.
Query: `empty → loading(local) → results | none | failed` with progressive background server verification and live/history slice merging; outdated searches are cancelled and any stale local or remote answer is dropped when the query changed.

## 7. Data models
`SearchIndexEntry`, `SearchQuery`, `RoomSearchCoverage`, `SearchHistorySlice`, `SearchIndexOperation`, `SearchTokeniser`, `SearchContent`, `SearchIndexPolicy`, `RoomSearchNavigator`, `RoomSearchIndexNotice` (pure, `HaloDomain`). Schema: [../data/DATA_MODELS.md](../data/DATA_MODELS.md) §3b.

## 8. API boundaries
`SearchPort` (UI-facing; `LocalMessageSearch` behind `CurrentSearchPort`), `LocalSearchIndexPort` / `AccountSearchIndexPort` (`SearchIndexStore`, HaloPersistence; the second adds the file's open/close/delete lifecycle), `MessageIndexSourcePort` (`MatrixMessageIndexSource`, adapter), `SearchIndexer`, `SearchCoordinator` and `MessageSearchEngine` (HaloApplication; the per-account lifecycle: attach, lock/unlock, background task, sign-out deletion; the app supplies only iOS's device state, lock state and processing task). Only the adapter sees SDK types; the index never feeds the timeline, the room list or unread state.

## 9. Error scenarios
Index damaged or of an older schema → deleted and rebuilt, search says "indexing" · disk full → the write fails, the rooms are read again later, search keeps working · server refuses history → room blocked with the reason · offline → local results only, hits outside the cache open with an explanation · index unreadable while locked → search unavailable until unlock.

## 10. Edge cases
Late or wrong timestamps · a message deleted or edited while its part of the room wasn't loaded (FR-11) · a message decrypted weeks later · event-focused paging anchored inside a thread (anchor only on events outside threads) · room upgraded (both rooms stay searchable) · left or forgotten room (entries removed) · ignored and un-ignored sender · history visibility that starts at joining · soft logout (index kept) · sign-in with another account (own file) · galleries with several files in one event · a message whose only newer messages are in threads (a gap is read from outside threads).

## 11. Acceptance criteria
- AC-SRCH-1 A word in an **encrypted** room is found: in a message received live, in one received before this run, and, after the recovery key is entered, in one sent before this device signed in.
- AC-SRCH-2 A message in an encrypted room that couldn't be decrypted is found after its key arrives, without reopening the room.
- AC-SRCH-3 Searching makes no request that contains the query; the only requests are for history, keys and opening a hit.
- AC-SRCH-4 The oldest message of a 20,000-event room is found after the history lane finished; killing the app during it repeats at most one slice.
- AC-SRCH-5 "今天去AppleStore" is found by 今天, 天去, apple and AppleStore, and not by 天今; "Café" by cafe.
- AC-SRCH-6 Deleted messages, messages of ignored people and messages of left rooms are never shown.
- AC-SRCH-7 No query crashes or errors: quotes, `*`, `OR`, `NEAR(`, punctuation only, 10,000 characters.
- AC-SRCH-8 After sign-out or revocation nothing of the index or the holding file is left on the device.
- AC-SRCH-9 `scripts/scale-measure.py scale1000` with search as shipped meets §4, and S01–S29 stay green.

## 12. Test requirements
Unit (Linux): tokeniser and query builder (AC-SRCH-5, 7), policy and coverage (out-of-order, future and late events), coordinator (stale results, load-more guard), `RoomSearchNavigator` and `RoomSearchIndexNotice` (M20-11), `MessageSearchEngine` room-coordinator isolation. Store (macOS): upsert, edit, delete, room leave, ignore, rebuild, wipe, paging. UI/Feature (`FeatureTimelineTests`): `RoomSearchViewModelTests` (room filter, stepping across pages, M20-1 focused jump, empty/indexing/error/thread states, Light/Dark/AX5 bar snapshots).
Contract (`infra/test/run.sh search`): encrypted room live, after recovery (recovery key), an event without a key, kill and resume, gaps of several pages and under reactions, deletion and edit live and while away, polls, files, threads, left room, opening a message 1,300 back, room-scoped search + focused jump (`inRoomSearchAndFocusedJump`). Scale: `scale1000` and the 20,000-event room. Open: UI test of the coverage notice, AX5, VoiceOver. 📱: locked phone, processing task, first sync of `scale1000`.

## 13. Open questions
None on design; V-SEARCH-2 still needs an iPhone ([../OPEN_QUESTIONS.md](../OPEN_QUESTIONS.md)).
