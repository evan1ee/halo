# Migrations

## 1. `halo.sqlite`
- GRDB `DatabaseMigrator` with named, append-only migrations: `v1_read_state`, `v2_stickers`, `v3_bots`, … Never edit a shipped migration.
- Migrations run inside the app **and** the NSE (whichever opens the database first); GRDB serialises them through SQLite locking. The NSE refuses to run a migration that takes longer than 1 s (it opens read-only and degrades instead) **[DECISION D53]**.
- Each migration has a test that starts from every earlier released schema (fixtures in `HaloPersistenceTests/Fixtures/schema-vN.sqlite`) and checks the data. *The fixtures don't exist yet* (ROADMAP M18-5).
- `eraseDatabaseOnSchemaChange` only in debug builds.
- Failure → recovery per [../architecture/ERROR_HANDLING.md](../architecture/ERROR_HANDLING.md) §4 (move aside, recreate; derived data rebuilds; unsent intents may be lost — logged).

## 1b. `search-index.sqlite` (*not built*, D123)
Derived data: no migrations. A version in `PRAGMA user_version`; any other version, or a file that can't be opened, is deleted and indexing starts again. On the first start with this index the SDK's `search-index` folder is deleted.

## 2. Account data (`one.mbm.halo.*`)
Versioned JSON (`version` field). Readers accept `version ≤ current`, upgrade in memory, and write back the current version only when changing something. Unknown higher versions → read-only mode for that feature with a notice ("Update Halo to edit stickers").

## 3. SDK stores
Owned by the SDK; migrated by the SDK on open. SDK bumps that change stores are noted in the bump checklist ([../development/BUILD_AND_RELEASE.md](../development/BUILD_AND_RELEASE.md) §3). Downgrades aren't supported — TestFlight builds never go back to an older SDK.

## 4. Keychain items
Item names carry a version suffix (`session.v1`); a new format adds `v2` and migrates on first read.
