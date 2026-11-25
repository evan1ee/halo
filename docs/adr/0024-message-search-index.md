# ADR-0024: Halo's own full-text index for message search

- **Status:** Accepted; built with M19-11 (2026-11-25). Open: an iPhone (V-SEARCH-2)
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
- **Source:** events are read in the adapter after the SDK decrypted them.
- **Two lanes (as corrected by M17-8):** *live*: the SDK's per-room event listeners (`m.room.message`, `m.room.encrypted`) deliver what sync brings, decrypted; an event that couldn't be decrypted arrives with its ID and is fetched again later. Whether a response hid messages is decided by comparing the room's 30 newest message IDs with the server (`/messages`, one request per touched room after a start or pause); gaps are read by the history lane. (*Corrected in M19-11:* the spike counted ten events per response, but reactions and state events fill a response too and aren't seen by these listeners.) *History*: per room, from an anchor event to the room's start, with event-focused timelines in **a client of its own**: same account, keys and state store (cross-process lock holder `search`), an event cache folder of its own, no sync, no send queue, dropped after about 20 rooms or 5,000 events.
- **Not in the app's client, not in live timelines:** a timeline read in the app's client leaves 20–25 KB behind each time and event-focused caches are never dropped (F-FFI-26); paging a live timeline feeds the SDK's in-memory index (0.4 s CPU and threads per room).
- **Automatic back-pagination stays on** (as today), so latest events and unread evidence don't change; only the index store goes (the unread suite is green either way; on costs 0.7 s of catch-up and saves 348 requests).
- **No timestamp watermark:** what is known is decided by event ID, and each room has a coverage record. Timestamps come from other servers and can be wrong, late or in the future.
- **Derived only:** the index supplies event IDs and snippets. Each shown page is re-checked, which corrects edits, deletions and ignored senders. (*Corrected in M19-11:* against the server's `/event`, because the SDK answers from its event cache, which a deletion inside a sync gap never reaches; the SDK is asked only for the text of an encrypted edit.) Losing the file loses nothing but time.
- **At rest (D124):** `complete` protection in the app's private folder, no backup; an encrypted holding file for history fetched while locked.
- **Replace, don't merge:** one `SearchPort` implementation; the SDK index is switched off and its folder deleted.

## Rationale
FTS5 is in the system SQLite GRDB already uses: no new dependency, one file, one writer. The messages are already decrypted on this device by the SDK; only the index is new. An event-focused timeline avoids growing the SDK's event cache with years of history, and dropping its client returns the memory (80,000 events: flat at 34 MB).

## Trade-offs
- Readable message text in one more file while the phone is unlocked (D124); FTS5 can't search encrypted columns, so NFR-7 gets an exception.
- Full history takes time, data and space: about 0.5 KB per message (300,000 generated messages: 145 MB on the dev Mac), and an estimated one to two hours of active work per million messages.
- The SDK keeps indexing new events in memory even without an index folder (F-FFI-25); the measured "index off" numbers include that. Removing it needs an upstream change.
- Direct HTTP reads (`/messages` for IDs, `/event`) with the session's token; no query text is in them.
- A second SDK client in the app's process: it must share the keychain session (token refresh, R-11) and be gone before sign-out, like the extensions'.
- The anchor of a room never read before costs one `/messages?limit=1` request over direct HTTP, because the SDK's latest event has no ID (F-FFI-15).

## Consequences
- M17-8 (spike) comes before G-SCALE; M19-11 builds the index; **M20-1 (jump to any message) becomes a prerequisite** of shipping it, because search finds what the timeline can't reach today.
- New port `LocalSearchIndexPort`, a new store in `HaloPersistence`, a new indexer port in the adapter (PORTS_CONTRACT).
- Sign-out, revocation, leaving or forgetting a room, and ignoring someone remove their entries (AC-SEC-4).
- Background rule 2 gets one exception: the history lane may open an event-focused timeline in a processing task.

## Verified facts and assumptions
- [VERIFIED M19-11, 2026-11-25, `infra/test/run.sh search`] The design as built: 400 encrypted messages found after recovery, live decrypted messages, 150 missed messages under twelve reactions, kill and resume, edits and deletions made while away, a message 1,300 back opened in 0.04 s.
- [VERIFIED F-FFI-25] `runSearchBackfill` and the back-pagination queue; the in-memory default; event-focused timelines; key download after a failed decryption. Read in source at `b93751e`, not run.
- [VERIFIED F-FFI-11] The SDK index exists and is encrypted at rest.
- [VERIFIED] System SQLite FTS5 (3.49.1, Python on the dev Mac, 2026-11-25): separate character prefixes `"今"* "天"*` also match reversed text, the phrase `"今 天"*` doesn't; an empty query is a syntax error; diacritics fold. GRDB 7.12.0 builds with `SQLITE_ENABLE_FTS5`.
- [VERIFIED V-SEARCH-2, simulator, 2026-11-25] Reading and indexing stays inside the budgets at 1,000 rooms with this design (TEST_STRATEGY §7). Not measured: an iPhone, energy, a real account.
- [VERIFIED V-SEARCH-3, 2026-11-25] 400 of 400 messages under 40 keys decrypted on a new device after recovery, 41 key requests, none before; the app's own timeline healed within seconds (`SearchSpikeEncryptionTests`).
