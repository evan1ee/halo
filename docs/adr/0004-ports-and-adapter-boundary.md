# ADR-0004: Halo-owned ports as the stable Swift ⇄ Matrix contract

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D44 · **Validation:** contract tests

## Context
The founder requires that Halo's domain logic never depends on upstream FFI types and that matrix-sdk-ffi can be replaced by Halo-owned bindings without rewriting domain or feature modules.

## Problem
How to define a stable boundary between Halo and whatever Matrix binding sits underneath?

## Considered alternatives
1. **Ports & adapter**: protocols in `HaloDomain` using Halo value types; one adapter module maps upstream ⇄ domain.
2. Use upstream types directly in view models (Element-style).
3. A thin "facade" class re-exporting upstream types.

## Decision
Option 1 ([../matrix/PORTS_CONTRACT.md](../matrix/PORTS_CONTRACT.md)).

## Rationale
Only option 1 makes the binding replaceable and the domain testable on Linux with fakes; option 3 still leaks upstream types.

## Trade-offs
Mapping code and duplication of some model shapes; a small latency for copying values; ports must be designed carefully up front.

## Consequences
`check-boundaries.sh` enforces the rule; each port has fakes and contract tests; port changes are versioned (PortsVersion).

## Verified facts and assumptions
None beyond ADR-0002.
