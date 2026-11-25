# Feature: Message Search

> Priority: P2 · Milestone: M8 (SDK index, shipped) → M17-8 / M19-11 (own index, **not built**) · Owner modules: FeatureSearch, HaloApplication, HaloDomain, HaloMatrixAdapter, HaloPersistence · Requirements: R-P2-SEARCH

Decisions: D30, D123, D124, ADR-0024. Sections 3–12 describe the target; what exists today is the SDK's `SearchService` behind `SearchPort`
(text, file names and captions, up to about three months back). It indexes encrypted rooms too by its design, but Halo's `messageSearch` contract test only uses an unencrypted room, so that is not tested.

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
- FR-4 **Content:** text, notice and emote bodies (Markdown source and reply fallback stripped), captions, file names, link addresses, sender names, poll questions and options. Not: reactions, state events, media contents, locations' coordinates.
- FR-5 **Languages:** normalised (NFKC), case and diacritics ignored. Runs of CJK characters are split into characters on writing and matched as a **phrase** on reading; Latin words match by prefix. One tokeniser for index, query and highlighting. Scripts without spaces that aren't CJK (Thai, Lao, Khmer) match by prefix of the whole run only.
- FR-6 **Query safety:** user text never reaches FTS5 as syntax; tokens are quoted; a query without any token returns no results and no error.
- FR-7 **Order and paging:** newest first, paged by (time, row). No relevance ranking.
- FR-8 **Filters:** room (used by M20-11) and kind: messages, media, files, links.
- FR-9 **Live lane:** the SDK's per-room listeners deliver each synced message, decrypted; undecryptable ones are kept by ID and fetched again when keys arrive. Rooms with ten or more events in one response are read back to a known event (possible gap). Listeners are registered before the first sync of a run.
- FR-10 **History lane:** starts by itself when sync is quiet; most recent rooms first; one room at a time, in slices; stores its position after each slice; runs in an SDK client of its own that is dropped about every 20 rooms or 5,000 events (ADR-0024); stops for Low Power Mode, thermal state serious or worse, mobile data (setting, default off), server rate limits and anything the person is doing; goes on in a processing task on the charger.
- FR-11 **Re-check before showing:** each page of hits is read from the SDK; a deleted event is removed from the index and not shown, an edited one is updated, an ignored sender is hidden.
- FR-12 **Opening a hit** goes to the event, in its thread if it is in one, through M20-1. Too old, gone or offline is said.
- FR-13 **Coverage notice:** "Searched back to <month> · n of m chats complete", plus how many messages can't be decrypted, with a way to verification when the device isn't verified.
- FR-14 **Settings → Storage:** index size, progress, pause, delete and rebuild.

## 4. Non-functional requirements
NFR-14 and NFR-15 hold with the index on: at 1,000 rooms first sync ≤ 60 s, catch-up ≤ 10 s, ≤ 1 s CPU per idle minute once the history lane is done or paused, ≤ 20 MB extra memory (met on the simulator, TEST_STRATEGY §7; the listeners' 22 MB is at the limit).
First results ≤ 200 ms p95 at 300,000 messages (simulator: ≤ 52 ms). NFR-4: no message text, file name, address or query in logs. Protection at rest: [../security/SECURITY.md](../security/SECURITY.md) §4.

## 5. User flows
Pull down on the chat list → type → chat names and "Messages" → tap a hit → the room or thread at that message.
First use on a large account: results appear at once for what is indexed, with the coverage notice.

## 6. State transitions
Room coverage: `none → live → partial(oldest event) → complete`, or `partial → blocked(noAccess | rateLimited)` and back.
Indexer: `idle → live → history → paused(reason) → history`; `stopped` on sign-out, revocation and background without a task.
Query: `empty → debouncing → loading → results | none | failed`; a result carries the query it answers and is dropped when the query changed.

## 7. Data models
`SearchIndexEntry`, `SearchIndexQuery`, `SearchCoverage`, `SearchTokeniser`, `SearchIndexPolicy` (pure, `HaloDomain`). Schema: [../data/DATA_MODELS.md](../data/DATA_MODELS.md) §3b.

## 8. API boundaries
`SearchPort` (UI-facing, one implementation), `LocalSearchIndexPort` (HaloPersistence), `MessageIndexSourcePort` (adapter: live and history slices as `SearchIndexEntry`), `SearchIndexer` (HaloApplication). Only the adapter sees SDK types; the index never feeds the timeline, the room list or unread state.

## 9. Error scenarios
Index damaged or of an older schema → deleted and rebuilt, search says "indexing" · disk full → indexing stops, search keeps working, Settings says it · server refuses history → room blocked with the reason · offline → local results only, hits outside the cache open with an explanation · index unreadable while locked → search unavailable until unlock.

## 10. Edge cases
Late or wrong timestamps · a message deleted or edited while its part of the room wasn't loaded (FR-11) · a message decrypted weeks later · event-focused paging anchored inside a thread (anchor only on events outside threads) · room upgraded (both rooms stay searchable) · left or forgotten room (entries removed) · ignored and un-ignored sender · history visibility that starts at joining · soft logout (index kept) · sign-in with another account (own file) · galleries with several files in one event.

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
Unit (Linux): tokeniser and query builder (AC-SRCH-5, 7), policy and coverage (out-of-order, future and late events), coordinator (stale results, load-more guard). Store (macOS): upsert, edit, delete, room leave, ignore, rebuild, wipe, paging.
Contract (dev Synapse): encrypted room live, after recovery (throwaway account, recovery key), late key, kill and resume, deletion and edit while not loaded, thread hit. Scale: `scale1000` and the 20,000-event room. UI: coverage notice, CJK query, AX5, VoiceOver. 📱: locked phone, processing task, first sync of `scale1000`.

## 13. Open questions
None on design; V-SEARCH-2 still needs an iPhone ([../OPEN_QUESTIONS.md](../OPEN_QUESTIONS.md)).
