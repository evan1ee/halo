# ADR-0006: GRDB SQLite in the App Group for app-owned data

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D40 (superseded), D46 · **Validation:** V-SQL-1, V-SQL-2, V-CI-1

## Context
Halo needs a small amount of app-owned, durable data (read intents, notification records, audit, caches, the bot index) shared by the app and the NSE. Matrix data itself stays in the SDK stores (single source of truth).

## Problem
Which database and where does it live, now that domain logic is Swift (D44)?

## Considered alternatives
1. **GRDB.swift (MIT) over system SQLite, file in the App Group, file protection + CryptoKit field encryption.**
2. SwiftData / Core Data.
3. A Rust-owned SQLite (the earlier D40) — no Halo Rust in the MVP.
4. SQLCipher via GRDB.
5. Storing Halo data inside the SDK's stores (not possible through the FFI; would mix ownership).

## Decision
Option 1 ([../data/PERSISTENCE.md](../data/PERSISTENCE.md)).

## Rationale
GRDB: WAL `DatabasePool`, explicit migrations, observation, documented use in app extensions, MIT **[VERIFIED F-LIC-5]**, builds on Linux for tests (V-CI-1). SwiftData/Core Data: weaker control over multi-process writes and migrations. SQLCipher: another SQLite build and its notices for little gain over file protection + field encryption.

## Trade-offs
Two SQLite copies in-process (the SDK's bundled one inside its dynamic framework, and the system one) — must never open the same file (V-SQL-1); field encryption makes encrypted columns unqueryable (only titles/content are encrypted).

## Consequences
Every table is keyed by account; monotonic upserts for cross-process safety; NSE suspension handling per GRDB guidance (V-SQL-2).

## Verified facts and assumptions
[VERIFIED] SDK default feature `bundled-sqlite` (F-FFI-1); prebuilt product is a dynamic library (SOURCES pinned refs). [ASSUMPTION] V-SQL-1, V-SQL-2, V-CI-1.
