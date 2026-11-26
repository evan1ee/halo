# Logging, Diagnostics and Observability

## 1. Logging
- **[DECISION D58]** Swift: Apple `os.Logger` through a thin `HaloLog` facade in `HaloFoundation`, with subsystem
  `one.mbm.halo` (D63) and categories `session`, `sync`, `readstate`, `outbox`, `push`, `nse`,
  `stickers`, `bot`, `db`, `ui`.
- SDK logs: the adapter calls `init_platform(config: TracingConfiguration, use_lightweight_tokio_runtime:)`
  **once per process** **[VERIFIED F-FFI-13]**. `TracingConfiguration` has `log_level`, `trace_log_packs`,
  `extra_targets`, `write_to_stdout_or_system`, `write_to_files: TracingFileConfiguration?`, `sentry_config`.
  Halo: `log_level` `info` (debug builds) / `warn` (release), files in the App Group container
  (`logs/sdk/`), `sentry_config = nil` (never enabled). The NSE passes `use_lightweight_tokio_runtime = true`
  **[ASSUMPTION V-NSE-3: reduces NSE memory; measure]**.
- **Privacy**: interpolated values default to `.private`. Matrix IDs are logged as short hashes
  (`HaloLog.id(roomId)` → `!a1b2c3`); message bodies, keys, tokens and media URLs are **never** logged. See
  [../security/SECURITY.md](../security/SECURITY.md) §6.

## 2. Read-state auditor (debug + TestFlight builds)
- After every reconcile and every 10 minutes in the foreground, compare for each room: policy output, SDK counts,
  server counts, own receipt, local intent.
- Classify disagreements: *explained* (known reason code such as `SDK_STALE_PENDING_RECEIPT`, `ENC_SERVER_OVERCOUNT`, `INTENT_UNCONFIRMED`)
  or *unexplained*.
- Store as `audit_event` rows (room id hashed, counts, reason, app version, sync position) — max 5,000 rows, oldest pruned first.
- AC-U8 counts *unexplained* events.
- **Status [VERIFIED 2026-11-22, unit tests]:** `ReadStateAuditor` (HaloDomain, pure) classifies per room; `ReadStateCoordinator` runs it after every room-list or position change, on manual reconcile (`Reconcile now`), and every 10 minutes while in the foreground (`setForeground`, `defaultAuditInterval = 600 s`) when an `Audit` is attached (`AppRoot`, `#if DEBUG` and TestFlight `sandboxReceipt` builds, after the account database opens), writing only findings that are new for a room. Settings → Diagnostics shows the unexplained event counter (AC-U8) and exports a `.zip` archive (`DiagnosticsZipArchive`: `report.txt`, `app-logs.txt` from `RingLogSink`, `audit-events.jsonl`, and `room-snapshots.jsonl` with hashed room IDs and counts only). Codes: explained `INTENT_UNCONFIRMED`, `SDK_STALE_PENDING_RECEIPT`, `SERVER_BLIND`, `ENC_SERVER_OVERCOUNT`, `ENC_SERVER_ONLY`; unexplained `UNEXPLAINED_SERVER_UNREAD_HIDDEN`, `UNEXPLAINED_ATTENTION_WITHOUT_INPUT`, `UNEXPLAINED_MUTED_ATTENTION`. Property test: 10,000 random inputs never give an unexplained finding from the policy's own output.

## 3. Diagnostics export
Settings → Diagnostics → "Export": a zip with app/SDK logs, audit events, DB schema version, sync state,
anonymised room snapshots (hashed ids, counts only), and the stored MetricKit payloads (`metrickit/`, §4). Shared through the share sheet; never uploaded automatically.

## 4. Crash reporting
- **[DECISION D59]** No third-party crash SDK in the personal phase. Use Xcode Organizer / TestFlight crash reports
  and MetricKit (`MXMetricManager`) payloads saved to the diagnostics folder.
- Decided for the public release too (D114).
- **Built (M17-2):** `MetricKitRecorder` (HaloPlatform) subscribes at launch in the app; `MetricPayloadStore` keeps each payload's JSON in the app's own
  `Application Support/diagnostics/metrickit` (not the App Group, excluded from backups, `completeUntilFirstUserAuthentication`): at most 30 days, 40
  payloads, 2 MB, 512 KB each. They describe the device and app, not the account, so signing out keeps them.
- **Privacy:** call stacks hold binary names and offsets only. An Objective-C exception's message, format string and arguments may quote app data and are
  dropped (its type and name stay); anything shaped like a Matrix identifier or a link is blanked. Tested in `MetricPayloadStoreTests`.

## 5. Metrics (local only)
`HaloSignpost` (HaloFoundation) over `OSSignposter`, subsystem `one.mbm.halo`, category `performance` in every build and process; also in Release, where
the budgets are measured. Only the name is recorded: no identifiers, sizes or content. A path that didn't happen is dropped, not ended.

| Interval | From | To | Recorded by |
|---|---|---|---|
| `cold-start` | first line of `HaloApp.init` | the room list has rows | app; not for prewarmed, background or signed-out launches |
| `room-open` | the room is chosen: its chat-list row is tapped, or it is put on the navigation path another way | its rows are visible at the newest message (a frame before they are on screen) | `TimelineView` |
| `room-first-rows` | as `room-open` | the list first draws rows (the message area stops being empty; before the landing is confirmed) | `TimelineView` |
| `sync-catch-up` | before an immediate `/sync` (`timeoutMs` 0) | the SDK has processed and stored the response | `MatrixSessionPort` |
| `sync-long-poll` | before a long-poll `/sync` | as above; includes the server's waiting time | `MatrixSessionPort` |
| `image-decode` | before decoding one image or animation | decoded | `StickerImage` (thumbnails, stickers, GIFs); the plain `UIImage(data:)` sites follow with M19-1 |
| `main-thread-hang` | a main run-loop turn begins | it ended after 250 ms or more | `MainThreadHangs`, only when launched with `-HaloMeasureHangs YES` (performance suite) |
| `notification-service` | the extension got the push | the notification was handed to iOS | `NotificationService` |

XCTest reads them with `XCTOSSignpostMetric`: `HaloSignpostMetricTests` (every interval), `ImageDecodeSignpostTests`, and
`HaloUITests.testPerformanceSignpostsAreRecorded` (launch, sync and room open in the running app). `OSLogStore` can't: signposts aren't persisted.
Used with Instruments and by the performance suite ([../testing/TEST_STRATEGY.md](../testing/TEST_STRATEGY.md) §7).
