# ADR-0003: UniFFI (not a hand-written C ABI) for any Halo-owned FFI

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D44 · **Validation:** V-FFI-1, V-FFI-2

## Context
If gate G-FFI fails, Halo writes its own Rust layer over `matrix-sdk`/`matrix-sdk-ui` and exposes it to Swift.

## Problem
Which FFI technology should a Halo-owned Rust layer use?

## Considered alternatives
1. **UniFFI** (Mozilla), library mode.
2. Hand-written `extern "C"` API + cbindgen + Swift wrappers.
3. swift-bridge.

## Decision
UniFFI, same major version as the pinned SDK (0.32.x **[VERIFIED F-FFI-20]**).

## Rationale
Generates Swift for async functions, objects with reference counting, records, enums, errors and callback interfaces; upstream already uses it **[VERIFIED F-FFI-2]**, so tooling (`uniffi-bindgen generate --library`) and patterns (`TaskHandle`) carry over. A C ABI would require manual memory management, error marshalling and async bridging — high risk, no benefit here.

## Trade-offs
UniFFI generated code has a performance overhead per call (serialisation of records) and some type limitations; acceptable for coarse-grained, port-shaped APIs.

## Consequences
The Halo crate exports **port-shaped** coarse APIs; never links together with the upstream binary in one app (duplicate SDK) — switching is all-or-nothing.

## Verified facts and assumptions
[ASSUMPTION V-FFI-1] cancellation semantics of async calls; [ASSUMPTION V-FFI-2] panic → error mapping. Both checked before any Halo-owned FFI is written.
