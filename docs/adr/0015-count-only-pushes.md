# ADR-0015: Count-only pushes must not set the app badge

- **Status:** Accepted — **partially implemented** (app and NSE strip/ignore `aps.badge` and server counts; `infra/sygnal/` Halo pushkin not yet built, tracked under R-24 in [../CODEBASE_REVIEW.md](../CODEBASE_REVIEW.md) as a pre-TestFlight release blocker) · **Date:** 2026-11-19 · **Decision IDs:** D5, D9, D11, D65 (amends ADR-0010) · **Validation:** V-PUSH-5

## Context
ADR-0010 sends event pushes as `event_id_only` through Sygnal to the NSE, which recomputes the badge with `BadgeCalculator` (D9).
Reading the pinned Synapse and Sygnal code showed a second kind of push the design didn't cover:

- Synapse sends a **count-only notification** (no event id, no room id) every time the user's badge changes after a receipt,
  whatever the pusher's `format` **[VERIFIED F-PUSH-1]**. Its count is the server's: invites plus rooms with a non-zero
  notification count, which overcounts encrypted rooms (UNREAD_STATE C4).
- Sygnal turns it into `{"aps": {"badge": N}}`, with no alert and without `default_payload` **[VERIFIED F-PUSH-2]**. iOS applies it to
  the icon directly: the NSE doesn't run and the app doesn't wake.

So after every read on any device, the icon would show the server's count instead of Halo's (a direct breach of D5/D9, cause C5),
and the "read elsewhere" wake-up that D11 and BACKGROUND_EXECUTION rely on would never happen.

## Problem
How do we stop count-only pushes from overwriting the badge, and can we use them to wake the app as D11 intends?

## Considered alternatives
1. **A Halo pushkin for Sygnal** (`infra/sygnal/`, Python, subclass of Sygnal's APNs pushkin, loaded by class name **[VERIFIED F-PUSH-3]**):
   it turns a count-only notification into a background push (`aps.content-available = 1`, no `badge`, `apns-push-type: background`,
   priority 5) and passes event pushes through without any server count.
2. **A filtering relay in front of Sygnal** that drops count-only notifications (`id == ""` and no `event_id`) and strips `counts`.
3. **Accept the server badge** until the next NSE run or app foreground.
4. Patch Synapse to stop sending them for Halo's pusher.

## Decision
**Option 1, with option 2 only as a fallback**, under these conditions (founder, 2026-11-19):

1. **The server never controls the iOS badge.** No push that reaches the device carries `aps.badge`. The pushkin removes `aps.badge`
   from every payload it builds (also if it appears in a `default_payload`), and Halo's pusher `default_payload` never contains it.
   Server counts (`unread_count`, `missed_calls`) are stripped from event payloads too; Halo never reads them (cause C5).
2. **The local unread engine is the sole authority for the badge.** Only the app and the NSE set it, only via `BadgeCalculator` over
   `ReadStatePolicy` results computed from synchronised Matrix state (D9, D65).
3. **Pushes are hints, not truth (D65).** A converted count-only push only wakes the app to reconcile from sync; an event push only
   triggers the NSE to fetch the event through the SDK. Nothing in a payload is used as read state or as a count.
4. **The relay is a fallback, not the long-term solution.** It is used only if V-PUSH-5 fails in M1 or a Sygnal bump breaks the
   pushkin. While it is active, risk T-BADGEPUSH stays open and returning to the pushkin is a tracked task; the relay never forwards
   a count-only notification and never forwards `counts`.

## Rationale
Option 1 removes the wrong badge **and** delivers the read-elsewhere signal as a background wake-up, which makes D11 work as
designed. Option 2 removes the wrong badge but leaves read-elsewhere clearing to the next foreground or NSE run (still within D11's
"best effort"), so it's acceptable only as a fallback. Option 3 contradicts D5/D9, the project's main promise. Option 4 is a fork of
the homeserver to maintain.

## Trade-offs
Option 1 is Halo-owned server code (a small Python class against Sygnal's internal pushkin API) that has to be re-checked on every
Sygnal bump (risk T-PUSHKIN); Sygnal's per-app `push_type` applies to all pushes of an app **[VERIFIED F-PUSH-3]**, so the subclass must
choose the push type per notification (V-PUSH-5). iOS throttles background pushes, so the wake-up stays best effort. Server code isn't
distributed, so it creates no licence duty for the app (Sygnal is Apache-2.0, F-LIC-8).

## Consequences
- `infra/sygnal/` holds the pushkin, pinned to the Sygnal version in `infra/`, with unit tests over Synapse notification fixtures:
  a count-only notification yields a background payload; **no output ever contains `aps.badge`**; event payloads carry no counts
  (CI job `pushkin.yml`, [../development/CI_CD.md](../development/CI_CD.md)).
- The NSE treats a push without `event_id` or `room_id` as "nothing to show" ([../matrix/PUSH_NOTIFICATIONS.md](../matrix/PUSH_NOTIFICATIONS.md) §3 step 0).
- On every foreground the app re-sets the badge from `BadgeCalculator` (already the rule), which limits the damage of a regression
  such as Sygnal deployed without the pushkin; the device checklist (TEST_STRATEGY §8) includes "read on another client → icon badge
  matches Halo's count while Halo stays in the background".
- ADR-0010's "badge recomputed locally" holds for every kind of push.

## Verified facts and assumptions
F-PUSH-1, F-PUSH-2, F-PUSH-3, F-LIC-8 [VERIFIED]. [ASSUMPTION V-PUSH-5] a Sygnal pushkin subclass can send background pushes for
count-only notifications while keeping alert pushes for events, and iOS delivers them to the app.
