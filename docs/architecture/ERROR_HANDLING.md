# Error Handling

## 1. Error taxonomy (domain level)

Upstream `ClientError` and other FFI errors **never** leave the adapter. The adapter maps them to:

```swift
// HaloFoundation — implemented in ios/Packages/HaloFoundation/Sources/HaloFoundation/HaloError.swift
public enum HaloError: Error, Sendable, Equatable {
  case network(retryable: Bool)          // offline, timeout, 5xx, rate limit (with retryAfter in context)
  case unauthorized(soft: Bool)          // token invalid → soft logout or full logout
  case forbidden                         // 403 on an action (power levels, ACL)
  case notFound                          // room/event/user gone
  case crypto(CryptoFailure)             // UTD reasons, verification failure, missing backup
  case invalidInput(String)              // validation (e.g. shortcode grammar)
  case unsupported(String)               // server lacks a capability Halo needs
  case storage(StorageFailure)           // DB open/migration/corruption
  case cancelled
  case `internal`(code: String)          // bug: never shown raw to users
}
```

Each case gets a stable `code` string for logs and diagnostics (e.g. `NET_TIMEOUT`, `AUTH_SOFT_LOGOUT`).

## 2. Rules
1. Every `throws` across a port throws `HaloError`.
2. Mapping happens in one place in the adapter (`ErrorMapper`), with unit tests per upstream error kind.
3. Views never show `error.localizedDescription` of an internal error; they show a user message chosen by case.
4. Retryable errors in background work → retry with exponential backoff and jitter (base 1 s, max 5 min); non-retryable → surface and stop.
5. No silent `try?` for operations that change state. `try?` is allowed only for best-effort cleanup, with a comment. *Not enforced yet: about 120 sites outside sleeps and fakes are unreviewed (ROADMAP M18-8).*
6. Every caught error in a coordinator is logged once, at the boundary where it is handled (no double logging).

## 3. User-visible states

| Situation | UI |
|---|---|
| Offline | Non-blocking banner "Offline — showing saved messages"; sends and receipts queue up |
| Send failed (retryable) | Message bubble with "Retry"; automatic retry in the background |
| Send failed (forbidden/unsupported) | Bubble with an explanation, "Delete" |
| Soft logout | Full-screen re-auth sheet; local data is kept |
| UTD | Placeholder explaining why (key not yet received / device not verified / no backup) |
| Storage failure | Recovery screen: "Rebuild local data" (keeps the session). *Not built* (ROADMAP M18-5) |

## 4. Recovery strategies

| Failure | Recovery |
|---|---|
| `SyncService` error state | Restart with backoff; after 3 failures show the banner; keep retrying |
| `halo.sqlite` corruption / failed migration | `HaloDatabase.openRecovering`: a damaged file (SQLITE_CORRUPT, NOTADB) or a migration that can't run is kept as `halo.sqlite.damaged` (one copy, replaced by the next) and a new DB is made; lost: drafts, unsent read receipts, notification records, bot tasks; logged. A file that is only busy, locked, on a full disk or unreadable before first unlock is left alone (`.storage(.unavailable)`). **Built** (M18-5) |
| `search-index.sqlite` damaged or of another version (D123) | Delete and rebuild in the background; search says it is indexing |
| SDK store corruption | The SDK says it only as text; `ErrorMapper.buildFailure` recognises garbage files ("disk I/O error") and a wrong store passphrase ("store cipher") as `.storage(.corrupted)` **[VERIFIED M18-5, `infra/test/run.sh store`]**. The launch screen then says the saved data is damaged, what is lost and what isn't, and offers "Sign out and start again" (plus "Try again", since the text can't tell damage from every transient failure). Not "Clear cache": the crypto store holds this device's keys, so a rebuilt store would be a different device under the same ID. **Built** (M18-5) |
| Push registration failure | Retry on the next foreground; the settings screen shows push status |
