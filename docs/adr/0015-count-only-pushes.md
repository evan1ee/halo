# ADR-0015: Count-only pushes must not set the app badge

- **Status:** Proposed · **Date:** 2026-11-19 · **Decision IDs:** D5, D9, D11 (amends ADR-0010 once accepted) · **Validation:** V-PUSH-5

## Context
ADR-0010 sends event pushes as `event_id_only` through Sygnal to the NSE, which recomputes the badge with `BadgeCalculator` (D9).
Reading the pinned Synapse and Sygnal code showed a second kind of push the design didn't cover:

- Synapse sends a **count-only notification** (no event id, no room id) every time the user's badge changes after a receipt,
  whatever the pusher's `format` **[VERIFIED F-PUSH-1]**. Its count is the server's: invites plus rooms with a non-zero
  notification count, which overcounts encrypted rooms (UNREAD_STATE C4).
- Sygnal turns it into `{"aps": {"badge": N}}`, with no alert and without `default_payload` **[VERIFIED F-PUSH-2]**. iOS applies it to
  the icon directly: the NSE doesn't run and the app doesn't wake.

So after every read on any device, the icon shows the server's count instead of Halo's (a direct breach of D5/D9, cause C5),
and the "read elsewhere" wake-up that D11 and BACKGROUND_EXECUTION rely on never happens.

## Problem
How do we stop count-only pushes from overwriting the badge, and can we use them to wake the app as D11 intends?

## Considered alternatives
1. **A Halo pushkin for Sygnal** (`infra/`, Python, subclass of Sygnal's APNs pushkin, loaded by class name **[VERIFIED F-PUSH-3]**):
   it turns a count-only notification into a background push (`aps.content-available = 1`, no `badge`, `apns-push-type: background`,
   priority 5) and passes event pushes through unchanged.
2. **A filtering relay in front of Sygnal** that drops count-only notifications (`id == ""` and no `event_id`).
3. **Accept the server badge** until the next NSE run or app foreground.
4. Patch Synapse to stop sending them for Halo's pusher.

## Decision
**Proposed:** option 1; option 2 as the fallback if V-PUSH-5 shows option 1 can't set the push type per notification. Decided by the
founder before M1 (Q-PUSH-BADGE).

## Rationale
Option 1 removes the wrong badge **and** delivers the read-elsewhere signal as a background wake-up, which makes D11 work as
designed. Option 2 removes the wrong badge but leaves read-elsewhere clearing to the next foreground or NSE run (still within D11's
"best effort"). Option 3 contradicts D5/D9, the project's main promise. Option 4 is a fork of the homeserver to maintain.

## Trade-offs
Option 1 is Halo-owned server code (a small Python class against Sygnal's internal pushkin API) that has to be re-checked on every
Sygnal bump; Sygnal's per-app `push_type` applies to all pushes of an app **[VERIFIED F-PUSH-3]**, so the subclass must choose the push
type per notification (V-PUSH-5). iOS throttles background pushes, so the wake-up stays best effort. Server code isn't distributed,
so it creates no licence duty for the app (Sygnal is Apache-2.0, F-LIC-8).

## Consequences
- `infra/` gains the pushkin (or the relay), with a test that a count-only notification never yields `aps.badge`.
- The NSE treats a push without `event_id` or `room_id` as "nothing to show" ([../matrix/PUSH_NOTIFICATIONS.md](../matrix/PUSH_NOTIFICATIONS.md) §3 step 0).
- On every foreground the app re-sets the badge from `BadgeCalculator` (already the rule), which limits the damage of a regression
  such as Sygnal deployed without the pushkin; the device checklist (TEST_STRATEGY §8) gains "read on another client → icon badge
  matches Halo's count while Halo stays in the background".
- ADR-0010's "badge recomputed locally" then holds for every kind of push.

## Verified facts and assumptions
F-PUSH-1, F-PUSH-2, F-PUSH-3, F-LIC-8 [VERIFIED]. [ASSUMPTION V-PUSH-5] a Sygnal pushkin subclass can send background pushes for
count-only notifications while keeping alert pushes for events, and iOS delivers them to the app.
