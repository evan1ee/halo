# Persistence

Decisions: D46, ADR-0006.

## 1. Stores at a glance

| Store | Owner | Location | Contents | Rebuildable? |
|---|---|---|---|---|
| SDK state + crypto store (SQLite) | matrix-rust-sdk | App Group `accounts/<hash>/data/` | Session, room state, crypto keys | No (keys!) — needs recovery key/backup if lost |
| SDK event cache + media store | matrix-rust-sdk | App Group `accounts/<hash>/cache/` | Cached events, media | Yes (from server) |
| `halo.sqlite` | HaloPersistence (GRDB) | App Group `accounts/<hash>/halo/halo.sqlite` | Intents, notification records, audit, caches, bot index | Yes, except unsent intents |
| `search-index.sqlite` (*not built*, D123) | HaloPersistence (GRDB, FTS5) | App's private Application Support `search/<hash>/`, excluded from backups | Text of decrypted messages, per-room coverage | Yes (from the SDK and the server; slow for full history) |
| Search holding file (*not built*) | HaloPersistence | App's private folder | History fetched while locked, AES-GCM, until it moves into the index | Yes |
| Keychain (shared access group) | HaloPlatform | — | Session tokens, SDK store passphrase, Halo DB field key | No |
| UserDefaults (App Group suite) | Features | — | UI preferences | Yes (defaults) |

`<hash>` = SHA-256 of the user id, first 16 hex chars (no raw user id in file paths).

## 2. Why GRDB (ADR-0006)
GRDB.swift v7.12.0 (MIT) **[VERIFIED F-LIC-5, SOURCES]**: mature SQLite toolkit; `DatabasePool` (WAL, concurrent reads); migrations API;
observation (`ValueObservation`) for UI updates; works in app extensions. Alternatives rejected: SwiftData/Core Data (multi-process
semantics and migrations less controllable), raw SQLite (boilerplate), Realm (heavier, different licence posture).

**SQLite copies.** The SDK bundles its own SQLite inside the dynamic `MatrixSDKFFI` framework (feature `bundled-sqlite`, F-FFI-1); GRDB uses the
system SQLite. Two SQLite libraries in one process are fine as long as **no file is opened by both** **[ASSUMPTION V-SQL-1: no symbol
interposition problem because the SDK's copy lives inside a dynamic framework (two-level namespace); verify in M0 with a smoke test
that opens both]**.

## 3. Data protection
- Every Halo file is created with `FileProtectionType.completeUntilFirstUserAuthentication` (the NSE must work while the device is locked after the first unlock).
- **Field encryption** for columns marked 🔒 in [DATA_MODELS.md](DATA_MODELS.md): AES-GCM (CryptoKit) with a 256-bit key from the Keychain (`afterFirstUnlockThisDeviceOnly`, shared access group). Format: `v1:` + base64(nonce ‖ ciphertext ‖ tag).
- Not encrypted: ids, timestamps, counts, states (needed for queries; metadata, protected by file protection).
- **Exception: `search-index.sqlite`** holds readable message text (FTS5 can't search encrypted columns); its protection is `complete` (D124, [../security/SECURITY.md](../security/SECURITY.md) §4). It is opened only while protected data is available, and only by the app.
- SQLCipher is **not** used (adds a third SQLite build and its own licence/notice duty, for little benefit given file protection + field encryption).

## 4. Multi-process access (app + NSE)
- One `DatabasePool` per process, WAL mode, `busy_timeout` 5 s; writes in short `IMMEDIATE` transactions.
- Monotonic upserts (e.g. `read_intent` only moves forward: `ON CONFLICT … DO UPDATE … WHERE excluded.event_ts > read_intent.event_ts`).
- After an NSE write, a Darwin notification `one.mbm.halo.db.changed` (D63) tells the app to re-read.
- **[ASSUMPTION V-SQL-2]** GRDB's guidance for sharing a database between an app and extensions (suspension handling: close/suspend the pool on background to avoid `0xdead10cc` terminations) is followed; verify in M1 with the NSE spike.

## 5. Cache strategy
| Cache | Policy |
|---|---|
| Decoded thumbnails (memory) | LRU 64 MB, cleared on memory warning |
| SDK media store (disk) | SDK retention policy (`set_media_retention_policy`), default 1 GB / 30 days **[DECISION D55; V-MEDIA-1]** |
| `sticker_pack_cache` | Refreshed on account-data/room-state change and at most every 6 h; served stale while refreshing |
| `bot_task` | Derived; rebuild on demand |
| `search-index.sqlite` (*not built*) | Kept until sign-out, account removal or "Delete" in Settings; a new schema version deletes and rebuilds it; not in Caches, because iOS would delete hours of indexing |

## 6. Offline behaviour and conflict resolution
| Data | Conflict rule |
|---|---|
| Read intents | Monotonic (the newest event wins); the server's receipt is final |
| Account data (`one.mbm.halo.*`, `m.image_pack.rooms`) | Read-modify-write with a merge function (favourites: union then trim; recents: merge by ts; preserve unknown keys). The base is the server's copy, read right before the write (`ServerAccountData`); if it can't be read, nothing is written (D120). Matrix has no conditional write, so two devices writing in the same moment can still lose one change |
| Room state (packs) | Last writer wins (Matrix state semantics); the editor reloads before writing |
| Bot tasks | The bot is the truth; the latest bot message (by `origin_server_ts`) wins |

## 7. State restoration
On launch: Keychain session → SDK client (cached rooms appear) → `halo.sqlite` opened → `ReadStateCoordinator` evaluates from SDK snapshots + intents immediately (cached badge first, then recomputed) → sync starts.

## 8. Deletion
Logout or account removal deletes the account's directory, its search index and holding file, Keychain items and badge cache. "Clear cache" deletes SDK caches and Halo caches but not intents or keys.
