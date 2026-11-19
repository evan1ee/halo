# ADR-0001: Monorepo

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D42 · **Validation:** none

## Context
One part-time developer (D24) builds an iOS app, its documentation, development infrastructure (Synapse, MAS, Sygnal) and possibly a Rust core later (G-FFI).

## Problem
Where should app code, docs, infrastructure and a future Rust core live?

## Considered alternatives
1. **Monorepo** `halo/` with `ios/`, `docs/`, `infra/`, `tools/`, later `core/`.
2. Separate repos (app, core, infra, docs).
3. Monorepo with git submodules for the SDK.

## Decision
Option 1. The SDK isn't vendored (it comes from SwiftPM as a pinned binary, ADR-0002).

## Rationale
Atomic changes across docs, ports and adapter; a single CI configuration; no version matrix between repos; simplest for one person; AI agents see the whole context.

## Trade-offs
A larger checkout; CI must filter by paths; access control is all-or-nothing (acceptable: private, solo).

## Consequences
Path-filtered workflows (CI_CD.md); CODEOWNERS by path when collaborators join; `core/` appears only if G-FFI fails.

## Verified facts and assumptions
None required.
