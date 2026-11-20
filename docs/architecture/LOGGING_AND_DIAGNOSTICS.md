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
- **Status [VERIFIED 2026-11-20, unit tests]:** `ReadStateAuditor` (HaloDomain, pure) classifies per room; `BadgeCoordinator` runs it after every room-list or position change when an `Audit` is attached (`AppRoot`, `#if DEBUG`, after the account database opens) and writes only findings that are new for a room. Codes: explained `INTENT_UNCONFIRMED`, `SDK_STALE_PENDING_RECEIPT`, `SERVER_BLIND`, `ENC_SERVER_OVERCOUNT`; unexplained `UNEXPLAINED_SERVER_UNREAD_HIDDEN`, `UNEXPLAINED_ATTENTION_WITHOUT_INPUT`, `UNEXPLAINED_MUTED_ATTENTION`. Property test: 10,000 random inputs never give an unexplained finding from the policy's own output. Not built: the 10-minute re-run, the diagnostics export, a counter in Settings.

## 3. Diagnostics export
Settings → Diagnostics → "Export": a zip with app/SDK logs, audit events, DB schema version, sync state,
anonymised room snapshots (hashed ids, counts only). Shared through the share sheet; never uploaded automatically.

## 4. Crash reporting
- **[DECISION D59]** No third-party crash SDK in the personal phase. Use Xcode Organizer / TestFlight crash reports
  and MetricKit (`MXMetricManager`) payloads saved to the diagnostics folder.
- Revisit before public release ([OPEN Q-CRASH]).

## 5. Metrics (local only)
Signposts (`OSSignposter`) for: cold start → room list, room open → first timeline frame, NSE duration, sync
round trip. Used with Instruments; performance tests read them ([../testing/TEST_STRATEGY.md](../testing/TEST_STRATEGY.md) §7).
