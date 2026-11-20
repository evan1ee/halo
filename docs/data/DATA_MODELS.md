# Data Models

Three kinds of model, never mixed:
1. **Domain models** (`HaloDomain`): `Sendable` value types used by features and policies.
2. **Persistence records** (`HaloPersistence`): GRDB records for app-owned tables; mapped to domain models in repositories.
3. **Upstream FFI types**: only inside `HaloMatrixAdapter`.

## 1. Identifiers
`UserID`, `RoomID`, `EventID`, `DeviceID` (in `HaloFoundation`, M0), later `TransactionID`, `MXCURI`: wrapper structs around
`String` with validation of the sigil (`@`, `!`, `$`), the 255-byte limit, and the server name for user IDs (room IDs don't require
one: not every room version includes it). Their `description` is redacted, so interpolating one into a log line never leaks it
(SECURITY §6); the raw value is `rawValue`. `AccountID = UserID`. `TimelineItemID` wraps the upstream unique id.

## 2. Domain models (key ones)

| Model | Fields (summary) | Defined in spec |
|---|---|---|
| `RoomSummary` | id, name, avatar, isDirect, isEncrypted, membership, latest: `LatestEventPreview?`, isFavourite, mode | [../features/ROOM_LIST.md](../features/ROOM_LIST.md) |
| `RoomReadInputs`, `RoomReadState` | see the spec | [../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md) §4 |
| `ReadIntent` | roomId, eventId, eventTs, createdAt, state (`pending`/`sent`), attempts | READ_RECEIPTS |
| `TimelineItem`, `TimelineDiff` | see the spec | [../features/TIMELINE.md](../features/TIMELINE.md) §7 |
| `MessageDraft`, `SendState` | text, mentions, replyTo | MESSAGING |
| `MediaRef`, `MediaInfo` | opaque source, mime, size, dims, duration, blurhash | MEDIA_ATTACHMENTS |
| `StickerPack`, `Sticker`, `StickerPrefs` | see the spec | [../features/STICKERS.md](../features/STICKERS.md) §8 |
| `BotMessageInput`, `ParsedCard`, `BotTaskRef`, `BotTask` | see the spec | [../features/BOT_MESSAGES.md](../features/BOT_MESSAGES.md) §7 |
| `SyncStatus`, `SessionEvent`, `VerificationState` | — | SYNC_ENGINE, AUTHENTICATION, ENCRYPTION |
| `HaloError` | see the spec | [../architecture/ERROR_HANDLING.md](../architecture/ERROR_HANDLING.md) |

## 3. Persistence schema — `halo.sqlite` (v1)

All tables have `account TEXT NOT NULL` (the user id) as the first key column (multi-account ready).
Content columns marked 🔒 are encrypted (see [PERSISTENCE.md](PERSISTENCE.md) §3).

```sql
-- read state (M3)
CREATE TABLE read_intent (
  account TEXT NOT NULL, room_id TEXT NOT NULL,
  event_id TEXT NOT NULL, event_ts INTEGER NOT NULL,       -- origin_server_ts (ms)
  created_at INTEGER NOT NULL, state TEXT NOT NULL CHECK (state IN ('pending','sent')),
  attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
  receipt_type TEXT NOT NULL CHECK (receipt_type IN ('read','read_private')),
  PRIMARY KEY (account, room_id)
);
CREATE TABLE draft (                                        -- unsent message per room (MESSAGING FR-5); local only
  account TEXT NOT NULL, room_id TEXT NOT NULL, body TEXT NOT NULL, updated_at INTEGER NOT NULL,
  PRIMARY KEY (account, room_id)
);
CREATE TABLE notification_record (
  account TEXT NOT NULL, event_id TEXT NOT NULL, room_id TEXT NOT NULL,
  event_ts INTEGER NOT NULL, is_mention INTEGER NOT NULL, delivered_at INTEGER NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('nse','app')),
  PRIMARY KEY (account, event_id)
);
CREATE INDEX notification_record_room ON notification_record(account, room_id, event_ts);
CREATE TABLE audit_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, at INTEGER NOT NULL,
  room_hash TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('explained','unexplained')),
  reason TEXT NOT NULL, inputs_json TEXT NOT NULL,          -- counts only, hashed ids
  app_version TEXT NOT NULL
);
CREATE TABLE badge_cache (account TEXT PRIMARY KEY, value INTEGER NOT NULL, computed_at INTEGER NOT NULL, source TEXT NOT NULL);

-- stickers (M4) — cache of parsed packs; truth is room state / account data
CREATE TABLE sticker_pack_cache (
  account TEXT NOT NULL, pack_room_id TEXT NOT NULL, state_key TEXT NOT NULL,
  content_json TEXT NOT NULL, fetched_at INTEGER NOT NULL,
  PRIMARY KEY (account, pack_room_id, state_key)
);
CREATE TABLE sticker_pack_draft (                           -- resumable creation
  account TEXT NOT NULL, draft_id TEXT NOT NULL, json TEXT NOT NULL, updated_at INTEGER NOT NULL,
  PRIMARY KEY (account, draft_id)
);

-- bots (M6–M7) — derived index; truth is the bot backend
CREATE TABLE bot_task (
  account TEXT NOT NULL, room_id TEXT NOT NULL, bot_sender TEXT NOT NULL,
  entity_type TEXT NOT NULL CHECK (entity_type IN ('todo','reminder')), entity_id INTEGER NOT NULL,
  source_event_id TEXT, title TEXT,                         -- 🔒 title
  status TEXT NOT NULL CHECK (status IN ('open','completed','deleted','unknown')),
  as_of_ts INTEGER NOT NULL, source_redacted INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL,
  PRIMARY KEY (account, room_id, bot_sender, entity_type, entity_id)
);
CREATE TABLE bot_action (
  account TEXT NOT NULL, room_id TEXT NOT NULL, bot_sender TEXT NOT NULL,
  entity_type TEXT NOT NULL, entity_id INTEGER NOT NULL,
  target_event_id TEXT NOT NULL, action TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('pending','failed')),
  started_at INTEGER NOT NULL, transaction_id TEXT,
  PRIMARY KEY (account, room_id, bot_sender, entity_type, entity_id)
);
```

## 4. Account data owned by Halo (synced via the homeserver)

| Type | Content | Spec |
|---|---|---|
| `one.mbm.halo.sticker_prefs` | favourites, recents (v1 schema in STICKERS §3) | STICKERS |
| `one.mbm.halo.sticker_rooms` | rooms created by Halo for personal packs | STICKERS |
| `one.mbm.halo.bot_allowlist` | `{ version: 1, bots: [userId] }` (synced allowlist) | BOT_MESSAGES |

Rules: every Halo account-data type has a `version` field; unknown fields are preserved on write; readers ignore unknown versions gracefully.
The `one.mbm.halo.*` namespace follows the spec's Java-package-style naming for custom types **[DECISION D54, D63]**.

## 5. Repository interfaces (ports, sketch)
`ReadIntentStore { upsertIfNewer(_:) ; markSent(room:) ; delete(room:, ifEventId:) ; all() ; observe() }`
`NotificationRecordStore { insertIfAbsent(_:) -> Bool ; covered(room:, upTo:) -> [EventID] ; delete(_:) }`
`AuditStore { append(_:) ; prune(max:) ; export() }`, `StickerPackCache`, `BotTaskStore { apply(_ event: BotIndexEvent) ; tasks(filter:) }`.
All mutating methods are idempotent and monotonic where stated.
