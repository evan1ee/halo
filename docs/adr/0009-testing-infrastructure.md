# ADR-0009: Testing infrastructure

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D35, D36 · **Validation:** V-CI-1

## Context
Correctness of read state must be proven under real server behaviour; the real Matrix stack only runs on Apple platforms; macOS CI minutes are expensive on private repositories.

## Problem
How to test deterministically and cheaply, including reproducing sync bugs?

## Considered alternatives
1. **Pure Swift policy + Linux scenario driver against real Synapse in Docker + local Mac FFI runs + trace replay.**
2. Everything on macOS CI with simulators.
3. Mock-server only (no real Synapse).

## Decision
Option 1 ([../testing/TEST_STRATEGY.md](../testing/TEST_STRATEGY.md)).

## Rationale
Real server semantics (counts, receipts) on cheap Linux runners; deterministic replay fixtures from any failure; FFI behaviour still covered locally.

## Trade-offs
SDK client-side counts are simulated in Linux runs (a reference counter) — mitigated by local FFI runs that compare real SDK inputs with the driver's.

## Consequences
`tools/scenario-driver`, `infra/test`, fixture format for traces, Linux-buildable core packages.

## Verified facts and assumptions
Sliding sync endpoint path [VERIFIED F-SPEC-5]. [VERIFIED F-CI-1] GRDB on Linux.
