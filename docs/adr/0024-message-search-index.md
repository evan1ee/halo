# ADR-0024: Halo's own full-text index for message search

- **Status:** Accepted with conditions (V-SEARCH-2 passes). **Not built** (2026-11-25)
- **Date:** 2026-11-25
- **Decision IDs:** D123, D124 (replaces the SDK index chosen under D30/V-SEARCH-1; resolves Q-SEARCH-INDEX)
- **Validation:** V-SEARCH-2 (cost), V-SEARCH-3 (encrypted history). If V-SEARCH-2 fails: option 2

## Context
Message search uses the SDK's `SearchService` over its Tantivy index (D30, F-FFI-11). At 1,000 rooms that index makes the first sync 3 to 4 times and the catch-up 13 to 20 times slower, and burns 25 s of CPU per idle minute (TEST_STRATEGY §7). It can't find Chinese or Japanese words inside a sentence and has no filters. The founder wants **encrypted rooms searchable** and **full history** (D123).

## Problem
Search every message this device can decrypt, in encrypted and unencrypted rooms, back to the start of each room, without slowing sync, leaking content, or becoming a second source of truth (AGENTS §4.1).

## Considered alternatives
1. **Keep the SDK index and tune its history sweep.** Rejected by measurement: without the sweep the numbers don't change (42.1 s, 12.6 s). With automatic back-pagination off, `runSearchBackfill` does nothing (F-FFI-25), so "off, then run it on demand" can't work either.
2. **SDK index, opt-in, default off.** The fallback: cheap to build, but whoever turns it on pays the full cost, and CJK and filters stay unsolved.
3. **Server-side search.** The server can't read encrypted rooms. Rejected for D123.
4. **Own SQLite FTS5 index (GRDB) filled from decrypted timelines.** Chosen.
5. **FTS5 over keyed token hashes, or SQLCipher.** Hashes lose prefix search and leak word frequencies; SQLCipher is another SQLite build and licence (ADR-0006). Rejected.

## Decision
Option 4. Behaviour: [../features/MESSAGE_SEARCH.md](../features/MESSAGE_SEARCH.md); files and schema: [../data/PERSISTENCE.md](../data/PERSISTENCE.md), [../data/DATA_MODELS.md](../data/DATA_MODELS.md).
- **Source:** events are read through SDK timelines in the adapter, after the SDK decrypted them. The sync event listener is not used: it never reports an event decrypted later (F-FFI-25).
- **Two lanes:** *live* (after each sync, read back to the first known event) and *history* (per room, from the oldest indexed event to the room's start, with an event-focused timeline, which resumes anywhere and is kept in memory only).
- **No timestamp watermark:** what is known is decided by event ID, and each room has a coverage record. Timestamps come from other servers and can be wrong, late or in the future.
- **Derived only:** the index supplies event IDs and snippets. Each shown page is re-checked against the SDK, which corrects edits, deletions and ignored senders. Losing the file loses nothing but time.
- **At rest (D124):** `complete` protection in the app's private folder, no backup; an encrypted holding file for history fetched while locked.
- **Replace, don't merge:** one `SearchPort` implementation; the SDK index is switched off and its folder deleted.

## Rationale
FTS5 is in the system SQLite GRDB already uses: no new dependency, one file, one writer. The messages are already decrypted on this device by the SDK; only the index is new. An event-focused timeline avoids growing the SDK's event cache with years of history.

## Trade-offs
- Readable message text in one more file while the phone is unlocked (D124); FTS5 can't search encrypted columns, so NFR-7 gets an exception.
- Full history takes time, data and space: about 0.5 KB per message (300,000 generated messages: 145 MB on the dev Mac), and an estimated one to two hours of active work per million messages.
- The SDK keeps indexing new events in memory even without an index folder (F-FFI-25); the measured "index off" numbers include that. Removing it needs an upstream change.
- Automatic back-pagination also serves the SDK's latest events and read-receipt search, so whether it stays on is measured, with the unread suite (V-SEARCH-2).

## Consequences
- M17-8 (spike) comes before G-SCALE; M19-11 builds the index; **M20-1 (jump to any message) becomes a prerequisite** of shipping it, because search finds what the timeline can't reach today.
- New port `LocalSearchIndexPort`, a new store in `HaloPersistence`, a new indexer port in the adapter (PORTS_CONTRACT).
- Sign-out, revocation, leaving or forgetting a room, and ignoring someone remove their entries (AC-SEC-4).
- Background rule 2 gets one exception: the history lane may open an event-focused timeline in a processing task.

## Verified facts and assumptions
- [VERIFIED F-FFI-25] `runSearchBackfill` and the back-pagination queue; the in-memory default; event-focused timelines; key download after a failed decryption. Read in source at `b93751e`, not run.
- [VERIFIED F-FFI-11] The SDK index exists and is encrypted at rest.
- [VERIFIED] System SQLite FTS5 (3.49.1, Python on the dev Mac, 2026-11-25): separate character prefixes `"今"* "天"*` also match reversed text, the phrase `"今 天"*` doesn't; an empty query is a syntax error; diacritics fold. GRDB 7.12.0 builds with `SQLITE_ENABLE_FTS5`.
- [ASSUMPTION V-SEARCH-2] Reading timelines and writing FTS5 rows stays inside the budgets at 1,000 rooms.
- [ASSUMPTION V-SEARCH-3] History of encrypted rooms from before sign-in decrypts through key backup while paging an event-focused timeline.
