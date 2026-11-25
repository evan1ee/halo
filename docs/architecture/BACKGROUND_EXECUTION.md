# Background Execution

iOS gives no persistent background connection. Halo relies on four mechanisms:

| Mechanism | Used for | Constraints |
|---|---|---|
| **NSE** (`UNNotificationServiceExtension`) | Decrypt and present every push; update notification records and the badge | Time and memory limited **[ASSUMPTION V-NSE-1: ~30 s, low memory limit; measure]** |
| **Background push** (`content-available`) | Synapse sends a count-only push whenever the badge changes after a receipt (e.g. read elsewhere) **[VERIFIED F-PUSH-1]**. Stock Sygnal turns it into an `aps.badge`-only push that sets the server's count on the icon and wakes nothing **[VERIFIED F-PUSH-2]**; Halo's pushkin (ADR-0015, accepted) converts it into a background push without `badge` → the app wakes briefly → reconcile + clear | Throttled by iOS; best effort (D11) **[ASSUMPTION V-PUSH-5]** |
| **BGAppRefreshTask** (`.backgroundTask(.appRefresh)`, asked for on every backgrounding, earliest after 15 min) | The same bounded catch-up as a silent push (`BackgroundRefresh`): session → room list → one `/sync` → evaluation written | Scheduled at iOS's discretion; the fallback when pushes are dropped or the gateway is down (D118) |
| **beginBackgroundTask** on backgrounding | Flush the receipt outbox and send queue, stop sync cleanly | ~30 s **[ASSUMPTION]** |
| **BGProcessingTask** `one.mbm.halo.search` (D123; not run on a device) | Search history lane on the charger with network (MESSAGE_SEARCH FR-10); while locked it writes only the encrypted holding file (D124) | iOS's discretion; expiration stops after the current slice |

## Rules
1. Background work is **idempotent** and safe to interrupt at any point (every step committed transactionally).
2. Background work never starts UI-only subscriptions (timelines). One exception (ADR-0024): the search history lane opens an event-focused timeline in its own SDK client for one slice and drops it.
3. The NSE never sends receipts or messages (it may be killed at any moment; the app owns outbound state).
4. On every foreground: full reconcile (see [DATA_FLOW.md](DATA_FLOW.md) §5) — the guarantee that catches up whatever best-effort background work missed.

5. Everything background work needs starts in `AppRoot.begin()`, called from `HaloApp.init`'s handlers as well as the view: iOS connects no scene for a background launch, so nothing a view starts exists then.
6. Report "done" to iOS only after the new counts are on the icon (`ReadStateCoordinator.waitForSync`), then suspend the databases: iOS suspends the app right after.
7. One sync at a time: a background pass waits for a stopping loop, the loop waits for a pass, and there is no pass while the loop runs.

## Identifiers (Info.plist)
- `BGTaskSchedulerPermittedIdentifiers`: `one.mbm.halo.refresh` (D63), `one.mbm.halo.search`.
- `UIBackgroundModes`: `remote-notification`, `fetch`, `processing`.
