# ADR-0016: Treat the NSE budget as its own gate, not a G-FFI criterion

- **Status:** Accepted (founder decision 2026-11-19) · **Date:** 2026-11-19 · **Decision IDs:** D44, D66 (amends ADR-0002's G-FFI criteria) · **Validation:** V-NSE-1, V-NSE-2, V-NSE-3, V-SQL-2

## Context
ADR-0002 lists three G-FFI criteria and schedules Halo-owned bindings (option 3) if any fails: (a) unread scenarios pass on upstream
data, (b) sticker state loading is solved within the port, (c) the NSE stays within its budget. Criteria (a) and (b) are about what
the upstream FFI *exposes*, so Halo-owned bindings can fix them. Criterion (c) is about memory and time spent by the SDK itself
(client, crypto store, runtime), which Halo-owned bindings over the same `matrix-sdk` would still load.

## Problem
What should happen when the NSE exceeds its budget, given that replacing the bindings doesn't obviously help?

## Considered alternatives
1. **Keep (c) in G-FFI** (status quo): a budget failure triggers 6–10 weeks of binding work that may not reduce memory.
2. **A separate gate G-NSE at the end of M1** (after the NSE spike), with an NSE-specific fail path: lightweight runtime (V-NSE-3),
   cached badge (V-NSE-2 fallback), generic content when out of time, and an SDK build from source without features the NSE doesn't
   need (e.g. `experimental-search`, `sentry`) via Q-SDK-BUILD. Halo-owned bindings only if measurements show the remaining cost is in
   the binding layer.
3. Drop decryption in the NSE (generic notifications only).

## Decision
Option 2. G-FFI keeps criteria (a) and (b); G-NSE is evaluated at the end of M1, independently of G-FFI. Its acceptance criteria
cover **memory usage, execution time, timeout handling, extension termination, network failures and fallback behaviour**:
AC-NSE-1…6 in [../features/NOTIFICATIONS.md](../features/NOTIFICATIONS.md) §11.

## Rationale
The fail path should be the cheapest change that can actually reduce the measured cost. Building the SDK with fewer features is
already planned (Q-SDK-BUILD) and needs no Halo Rust; moving G-NSE to M1 gives the answer three milestones earlier. Option 3 gives up
encrypted notification content (AC-N1).

## Trade-offs
One more gate to track; the feature-trimmed SDK build moves earlier if G-NSE fails (Rust toolchain needed sooner, M2 instead of M5).

## Consequences
- ROADMAP gates gain G-NSE (end of M1); ADR-0002's criterion (c) moves there.
- A G-NSE failure triggers only the NSE fail path above; it doesn't by itself fail G-FFI.
- The NSE spike in M1 records peak memory and duration per configuration (V-NSE-1/3) so the gate has numbers to judge.

## Verified facts and assumptions
SDK default features include `experimental-search` **[VERIFIED F-FFI-1]**; the upstream Swift build enables `sentry` **[VERIFIED F-LIC-2]**.
[ASSUMPTION V-NSE-1/3] NSE memory/time with the SDK and the effect of the lightweight runtime. [ASSUMPTION] Removing those features
reduces NSE memory — to be measured in the spike if G-NSE fails.
