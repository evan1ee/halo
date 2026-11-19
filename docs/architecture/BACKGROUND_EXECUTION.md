# Background Execution

iOS gives no persistent background connection. Halo relies on four mechanisms:

| Mechanism | Used for | Constraints |
|---|---|---|
| **NSE** (`UNNotificationServiceExtension`) | Decrypt and present every push; update notification records and the badge | Time and memory limited **[ASSUMPTION V-NSE-1: ~30 s, low memory limit; measure]** |
| **Background push** (`content-available`) | Synapse sends a count-only push whenever the badge changes after a receipt (e.g. read elsewhere) **[VERIFIED F-PUSH-1]**. Stock Sygnal turns it into an `aps.badge`-only push that sets the server's count on the icon and wakes nothing **[VERIFIED F-PUSH-2]**; Halo's pushkin (ADR-0015, accepted) converts it into a background push without `badge` → the app wakes briefly → reconcile + clear | Throttled by iOS; best effort (D11) **[ASSUMPTION V-PUSH-5]** |
| **BGAppRefreshTask** | Periodic short sync (`SyncService` start → wait until idle or 20 s → stop), reconcile, outbox flush | Scheduled at iOS's discretion |
| **beginBackgroundTask** on backgrounding | Flush the receipt outbox and send queue, stop sync cleanly | ~30 s **[ASSUMPTION]** |

## Rules
1. Background work is **idempotent** and safe to interrupt at any point (every step committed transactionally).
2. Background work never starts UI-only subscriptions (timelines).
3. The NSE never sends receipts or messages (it may be killed at any moment; the app owns outbound state).
4. On every foreground: full reconcile (see [DATA_FLOW.md](DATA_FLOW.md) §5) — the guarantee that catches up whatever best-effort background work missed.

## Identifiers (to register in Info.plist in M0)
- `BGTaskSchedulerPermittedIdentifiers`: `one.mbm.halo.refresh` (D63).
- `UIBackgroundModes`: `remote-notification`, `fetch`.
