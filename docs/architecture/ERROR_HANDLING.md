# Error Handling

## 1. Error taxonomy (domain level)

Upstream `ClientError` and other FFI errors **never** leave the adapter. The adapter maps them to:

```swift
// HaloDomain — illustrative signature, not implementation
public enum HaloError: Error, Sendable, Equatable {
  case network(retryable: Bool)          // offline, timeout, 5xx, rate limit (with retryAfter in context)
  case unauthorized(soft: Bool)          // token invalid → soft logout or full logout
  case forbidden                         // 403 on an action (power levels, ACL)
  case notFound                          // room/event/user gone
  case crypto(CryptoFailure)             // UTD reasons, verification failure, missing backup
  case invalidInput(String)              // validation (e.g. shortcode grammar)
  case unsupported(String)               // server lacks a capability (e.g. sliding sync)
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
5. No silent `try?` for operations that change state. `try?` is allowed only for best-effort cleanup, with a comment.
6. Every caught error in a coordinator is logged once, at the boundary where it is handled (no double logging).

## 3. User-visible states

| Situation | UI |
|---|---|
| Offline | Non-blocking banner "Offline — showing saved messages"; sends and receipts queue up |
| Send failed (retryable) | Message bubble with "Retry"; automatic retry in the background |
| Send failed (forbidden/unsupported) | Bubble with an explanation, "Delete" |
| Soft logout | Full-screen re-auth sheet; local data is kept |
| UTD | Placeholder explaining why (key not yet received / device not verified / no backup) |
| Storage failure | Recovery screen: "Rebuild local data" (keeps the session) |

## 4. Recovery strategies

| Failure | Recovery |
|---|---|
| `SyncService` error state | Restart with backoff; after 3 failures show the banner; keep retrying |
| `halo.sqlite` corruption / failed migration | Move the file aside (`halo.sqlite.corrupt-<ts>`) and create a new DB; derived data is rebuilt; log + auditor event |
| SDK store corruption | Offer "Clear cache" (`Client.clear_caches` **[VERIFIED F-FFI-4 list: `clear_caches`]**), then a full re-sync |
| Push registration failure | Retry on the next foreground; the settings screen shows push status |
