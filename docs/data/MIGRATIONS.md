# Migrations

## 1. `halo.sqlite`
- GRDB `DatabaseMigrator` with named, append-only migrations: `v1_read_state`, `v2_stickers`, `v3_bots`, … Never edit a shipped migration.
- Migrations run inside the app **and** the NSE (whichever opens the database first); GRDB serialises them through SQLite locking. The NSE refuses to run a migration that takes longer than 1 s (it opens read-only and degrades instead) **[DECISION]**.
- Each migration has a test that starts from every earlier released schema (fixtures in `HaloPersistenceTests/Fixtures/schema-vN.sqlite`) and checks the data.
- `eraseDatabaseOnSchemaChange` only in debug builds.
- Failure → recovery per [../architecture/ERROR_HANDLING.md](../architecture/ERROR_HANDLING.md) §4 (move aside, recreate; derived data rebuilds; unsent intents may be lost — logged).

## 2. Account data (`app.halo.*`)
Versioned JSON (`version` field). Readers accept `version ≤ current`, upgrade in memory, and write back the current version only when changing something. Unknown higher versions → read-only mode for that feature with a notice ("Update Halo to edit stickers").

## 3. SDK stores
Owned by the SDK; migrated by the SDK on open. SDK bumps that change stores are noted in the bump checklist ([../development/BUILD_AND_RELEASE.md](../development/BUILD_AND_RELEASE.md) §3). Downgrades aren't supported — TestFlight builds never go back to an older SDK.

## 4. Keychain items
Item names carry a version suffix (`session.v1`); a new format adds `v2` and migrates on first read.
