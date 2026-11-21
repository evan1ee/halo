# ADR-0019: Change the password with one direct HTTP call

- **Status:** Accepted (founder asked for "change password" in Settings on 2026-11-21; same rule as ADR-0018) · **Date:** 2026-11-21 · **Decision IDs:** D77 · **Validation:** none

## Context
Settings → Account → Change password. AGENTS.md §14 allows direct HTTP only where documented.

## Problem
The pinned SDK has no call that changes the account password (grep of `matrix_sdk_ffi.swift`: only `canChangePassword()` on the homeserver capabilities and `deactivateAccount`).

## Considered alternatives
1. Leave it out; send people to another Matrix app.
2. `POST /_matrix/client/v3/account/password` in the adapter, with password interactive authentication, behind `AccountPasswordPort`.
3. Open the homeserver's web account page.

## Decision
Option 2, in `MatrixAccountPasswordPort` only. Two requests: the first (no `auth`) returns the interactive-authentication session; the second repeats it with `m.login.password` proving the current password. `logout_devices` is sent as `false`, so other sessions stay signed in (the homeserver's default is to sign them out). The access token comes from the client for each call. The passwords exist only in memory for these requests, go only to the account's own homeserver, and are never logged or stored. Accounts that signed in through an external identity service (`oauthData` present) are not offered the screen. A wrong current password and a refused new password are told apart (`invalidInput` `CURRENT_PASSWORD` / `NEW_PASSWORD`), so the screen can say which.

## Rationale
It is the smallest change that delivers the screen and stays replaceable behind the port. Option 3 needs a browser round trip and an address Halo doesn't know.

## Trade-offs
Halo handles the user's passwords for the length of the call. Mitigation: no logging, no persistence, the model clears its fields after use.

## Consequences
A second direct-HTTP place to review in security audits (SECURITY.md); contract tests change the throwaway peer account's password and restore it.

## Verified facts and assumptions
- [VERIFIED] The client-server API defines `POST /_matrix/client/v3/account/password` with `new_password`, `logout_devices` and an `auth` object; the dev Synapse answers it (contract test `changePassword`).
- [VERIFIED] The pinned SDK has no password-change call.
