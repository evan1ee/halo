# ADR-0013: Clean-room development and licence gate

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D2, D37, D38, D39 · **Validation:** legal review before public release

## Context
Halo is proprietary. Element X iOS is AGPL-3.0 **[VERIFIED F-LIC-3]**. The founder previously forked and read Element X's source while experimenting.

## Problem
How to keep Halo's code independently authored and its dependencies compatible with proprietary distribution?

## Considered alternatives
1. **Behaviour-only reference + written policy + automated licence gate + generated notices.**
2. Read-allowed, no-copy policy.
3. Two-person clean room (impossible solo).

## Decision
Option 1 ([../security/LICENSE_COMPLIANCE.md](../security/LICENSE_COMPLIANCE.md), CONTRIBUTING.md).

## Rationale
The strongest practical position for a solo developer; the gate catches transitive surprises (verified: none today, F-LIC-2).

## Trade-offs
Some Element X implementation knowledge can't be reused; learning comes from specs, the Apache-2.0 SDK and observed behaviour.

## Consequences
No Element X source in the repo or AI prompts; nothing from the old fork; ⚖️ review of the prior exposure and this policy before public release.

## Verified facts and assumptions
F-LIC-1..8 [VERIFIED].
