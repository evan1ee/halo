# Background Execution

iOS gives no persistent background connection. Halo relies on four mechanisms:

| Mechanism | Used for | Constraints |
|---|---|---|
| **NSE** (`UNNotificationServiceExtension`) | Decrypt and present every push; update notification records and the badge | Time and memory limited **[ASSUMPTION V-NSE-1: ~30 s, low memory limit; measure]** |
| **Background push** (`content-available`) | Synapse sends count-only pushes when unread counts change (e.g. read elsewhere) → the app wakes briefly → reconcile + clear | Throttled by iOS; best effort (D11) **[ASSUMPTION V-PUSH-2: Synapse/Sygnal deliver these as background pushes with the chosen pusher config]** |
| **BGAppRefreshTask** | Periodic short sync (`SyncService` start → wait until idle or 20 s → stop), reconcile, outbox flush | Scheduled at iOS's discretion |
| **beginBackgroundTask** on backgrounding | Flush the receipt outbox and send queue, stop sync cleanly | ~30 s **[ASSUMPTION]** |

## Rules
1. Background work is **idempotent** and safe to interrupt at any point (every step committed transactionally).
2. Background work never starts UI-only subscriptions (timelines).
3. The NSE never sends receipts or messages (it may be killed at any moment; the app owns outbound state).
4. On every foreground: full reconcile (see [DATA_FLOW.md](DATA_FLOW.md) §5) — the guarantee that catches up whatever best-effort background work missed.

## Identifiers (to register in Info.plist in M0)
- `BGTaskSchedulerPermittedIdentifiers`: `app.halo.refresh` (name final once the bundle ID is chosen — [OPEN Q-BUNDLE]).
- `UIBackgroundModes`: `remote-notification`, `fetch`.
