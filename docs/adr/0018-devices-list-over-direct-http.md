# ADR-0018: List the account's sessions with one direct HTTP call

- **Status:** Accepted (founder picked "Devices list" on 2026-11-21 after being told it needs this call) · **Date:** 2026-11-21 · **Decision IDs:** D76 · **Validation:** none

## Context
Settings → Account → Sessions (SETTINGS §3) shows the places the account is signed in. AGENTS.md §14 allows direct HTTP calls only where documented.

## Problem
The pinned SDK has no call that lists devices (checked in `matrix_sdk_ffi.swift`: only `deviceId()`, dehydrated-device and verification calls). Without one, the screen cannot be built through the port boundary.

## Considered alternatives
1. Leave the screen out until the SDK exposes it.
2. One direct `GET /_matrix/client/v3/devices` call in the adapter, read-only.
3. A general HTTP client in the adapter for any endpoint the SDK lacks.

## Decision
Option 2, in `MatrixDevicesPort` only. It sends the session's access token (read from the client for each call, never stored, never logged) only to the account's own homeserver URL, over the scheme that URL has, with TLS verification untouched. It reads `device_id`, `display_name` and `last_seen_ts`; IP addresses in the response are ignored. Signing other sessions out (`DELETE /devices`) needs user-interactive authentication and is not built.

## Rationale
It is the smallest call that delivers the screen, it is read-only, and it stays behind `DevicesPort`, so it can be replaced by an SDK call the day one exists.

## Trade-offs
The token handling is Halo's, not the SDK's: after a token refresh the next call reads the new token from the client, but a refresh in the middle of the request would fail it with 401 (shown as "couldn't be loaded", retry works).

## Consequences
A new direct-HTTP place to review in security audits (SECURITY.md). Option 3 stays rejected: each further endpoint needs its own decision.

## Verified facts and assumptions
- [VERIFIED] The Matrix client-server API defines `GET /_matrix/client/v3/devices` returning `devices[]` with `device_id`, `display_name`, `last_ip`, `last_seen_ts`; the dev Synapse answers it (contract test `devicesList`).
- [VERIFIED] The pinned SDK has no device-list call (grep of `matrix_sdk_ffi.swift`).
