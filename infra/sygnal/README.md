# Halo Sygnal Pushkin (`infra/sygnal/`)

Custom APNs pushkin for Sygnal `v0.15.1` implementing [ADR-0015](../../docs/adr/0015-count-only-pushes.md) Option 1 (D65, R-24).

## Behaviour
- **Count-only notifications** from Synapse (no `event_id` and no `room_id`) are converted into silent background pushes (`{"aps": {"content-available": 1}}`, `apns-push-type: background`, `apns-priority: 5`) so iOS wakes Halo to reconcile from sync without touching the icon badge.
- **Event notifications** stay alert pushes (`apns-push-type: alert`, `apns-priority: 10`) with `aps.mutable-content = 1`, `event_id`, and `room_id` so the NSE fetches the event via the SDK and recomputes the badge locally via `BadgeCalculator`.
- **`aps.badge` and server counts** (`unread_count`, `missed_calls`, `counts`) are unconditionally stripped from every payload.

## Running unit tests
```bash
python3 -m unittest discover -s infra/sygnal -p "test_*.py" -v
```

## Building & running
```bash
docker build -t halo-sygnal:v0.15.1 infra/sygnal
```
Mount a rendered `sygnal.yaml` (based on `sygnal.yaml.example`) and your APNs `.p8` key under `/secrets` (never commit secrets).
