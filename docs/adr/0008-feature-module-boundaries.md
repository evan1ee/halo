# ADR-0008: Local Swift packages per layer and per feature

- **Status:** Accepted, refined by [ADR-0022](0022-module-layout-v2.md) (D86) · **Date:** 2026-11-19 · **Decision IDs:** D42, D44 · **Validation:** none

## Context
Independent feature development, testability on Linux for logic, a replaceable Matrix binding, future collaborators.

## Problem
How to structure Swift modules and enforce dependency directions?

## Considered alternatives
1. **Local SwiftPM packages per layer (Foundation, Domain, Application, Adapter, Persistence, Platform, DesignSystem, BotRendering, TestSupport) and per feature; Xcode project only for composition roots.**
2. One app target with folders.
3. Tuist/XcodeGen-generated multi-target project.

## Decision
Option 1 ([../architecture/MODULE_BOUNDARIES.md](../architecture/MODULE_BOUNDARIES.md)).

## Rationale
The compiler enforces imports; packages build and test in isolation (and on Linux for pure ones); fewer project-file conflicts. Project generators add tooling without a need at solo scale.

## Trade-offs
More `Package.swift` files; cross-package refactors are slightly slower; previews require fakes.

## Consequences
`check-boundaries.sh` adds rules the compiler can't express (no upstream types in public signatures, no feature → feature imports).

## Verified facts and assumptions
None.
