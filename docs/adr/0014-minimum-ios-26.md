# ADR-0014: Minimum iOS 26

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D25 · **Validation:** none

## Context
Personal phase first (D1); newest SwiftUI and Observation; optional on-device AI later (D18).

## Problem
Which deployment target?

## Considered alternatives
iOS 26 · iOS 18 · iOS 17.

## Decision
iOS 26.0.

## Rationale
Fewer compatibility branches for one developer; current SwiftUI scroll/observation APIs; the founder's devices run it. The SDK package supports older targets (`.iOS(.v16)` in its manifest **[VERIFIED F-FFI-19]**), so this doesn't constrain the SDK.

## Trade-offs
Smaller audience at public launch; revisit before M10 if needed.

## Consequences
No `if #available` branches below 26.

## Verified facts and assumptions
See above.
