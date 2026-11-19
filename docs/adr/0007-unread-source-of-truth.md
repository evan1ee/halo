# ADR-0007: Read-state source of truth and reconciliation policy

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D8 (superseded), D9, D47 · **Validation:** gate G-UNREAD

## Context
Wrong unread badges are the main reason for the project. Signals available through the FFI: server counts, SDK client-side counts, marked-unread, own receipts (event id + receipt time), latest event (timestamp, is_own) **[VERIFIED F-FFI-7, F-FFI-15]**. The SDK drops unmatched receipts beyond 10 per room **[VERIFIED F-SDK-1]**; servers overcount in encrypted rooms.

## Problem
What is the source of truth for "does this room need attention", and where is it computed, so that the room list, timeline, notifications and badge never disagree?

## Considered alternatives
1. **Reconciliation policy over SDK + server signals + Halo intents** (pure Swift, no recounting).
2. Trust the SDK's `num_unread_*` directly.
3. Trust the server counts only.
4. Halo's own independent recount from events (needs event-cache access → Halo-owned bindings).

## Decision
Option 1 ([../matrix/UNREAD_STATE.md](../matrix/UNREAD_STATE.md)): the server owns read positions and server counts; the SDK owns client counts; Halo owns only *intents* (pending receipts) and *notification records*; attention/badge are derived by one pure function. Option 4 only if G-UNREAD fails.

## Rationale
Avoids duplicating SDK business logic (counting) while fixing its known failure modes with rules that use the authoritative server signal (server-zero) and the user's local intent. Works identically in app and NSE. Pure → property-testable on Linux.

## Trade-offs
In encrypted rooms where the SDK hasn't seen new events, the count is approximate (shown as a dot). Ordering by timestamps has a federation clock-skew limitation.

## Consequences
No stored counts; the badge is always recomputed (D9); auditor compares all signals; scenario suite S01–S21 is the gate.

## Verified facts and assumptions
F-FFI-6/7/12/15, F-SDK-1, F-SPEC-1/2 [VERIFIED]. The "server zero ⇒ read" rule is a design decision **validated by scenarios S02, S04, S05**, and it applies only where the server can count (E2x, V-RS-6, S21) — not a spec guarantee.
