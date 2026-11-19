# ADR-0010: Push via Sygnal `event_id_only` + NSE

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D10, D11 · **Validation:** V-NSE-1/2/3, V-PUSH-1/2/3

## Context
E2EE content must be decrypted on device; the badge must not come from the server's message count.

## Problem
How do pushes reach the device and become correct notifications and badges?

## Considered alternatives
1. **Self-hosted Sygnal, `event_id_only`, NSE fetches + decrypts via `NotificationClient`, badge recomputed locally.**
2. Full-content pushes (no NSE decryption) — leaks content to the gateway, impossible for E2EE.
3. A custom push gateway.
4. A third-party gateway (e.g. matrix.org's) — requires their app id; impossible for a different app.

## Decision
Option 1 ([../matrix/PUSH_NOTIFICATIONS.md](../matrix/PUSH_NOTIFICATIONS.md)).

## Rationale
Sygnal is the reference gateway (Apache-2.0 [VERIFIED F-LIC-8]); `event_id_only` is supported by the FFI pusher API **[VERIFIED F-FFI-16]**; `NotificationClient` with `MultipleProcesses` exists for exactly this **[VERIFIED F-FFI-10]**.

## Trade-offs
Running Sygnal; NSE memory/time limits; suppression needs Apple's filtering entitlement.

## Consequences
Request the entitlement in M1; NSE spike in M1; generic default alert text in the pusher payload.

## Verified facts and assumptions
See the V-items above in OPEN_QUESTIONS.
