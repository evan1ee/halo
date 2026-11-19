# ADR-0005: `@Observable` view models + coordinators; no TCA

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D41 · **Validation:** none

## Context
iOS 26+ (D25), Swift 6 concurrency, high-frequency updates (timeline diffs, room list), solo developer.

## Problem
Which UI state architecture?

## Considered alternatives
1. **Observation (`@Observable`) feature view models + application-layer coordinators/use cases + AsyncStream**.
2. The Composable Architecture (TCA).
3. A home-made unidirectional store.
4. MVVM with Combine/ObservableObject.

## Decision
Option 1.

## Rationale
Native, fine-grained invalidation (Observation), no framework lock-in, low boilerplate, works with actors and AsyncStream; testable by injecting fake use cases. TCA's reducer overhead and dependency management fit poorly with high-frequency diffs and add a big dependency; a home-made store is framework maintenance; Combine is legacy for new code.

## Trade-offs
Less enforced structure than TCA → conventions in CODE_CONVENTIONS and reviews must hold the line (no logic in views, no infrastructure in view models).

## Consequences
View models are `@MainActor @Observable final class`; coordinators are actors in HaloApplication; DI by constructor + a root `AppContainer` passed through the Environment.

## Verified facts and assumptions
Observation is available since iOS 17 [VERIFIED: Apple documentation for the Observation framework] — well within iOS 26.
