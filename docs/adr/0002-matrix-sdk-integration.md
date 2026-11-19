# ADR-0002: Integrate matrix-rust-sdk through the upstream FFI binary, behind an adapter

- **Status:** Accepted (G-FFI criterion (c) moved to gate G-NSE by ADR-0016) · **Date:** 2026-11-19 · **Decision IDs:** D3 (superseded), D27 (superseded), D44 · **Validation:** gate G-FFI (end of M3), V-SDK-1

## Context
Halo needs a production-grade Matrix implementation (E2EE, sliding sync, timeline, notifications). matrix-rust-sdk provides it, with UniFFI bindings in `matrix-sdk-ffi`.

## Problem
How should a proprietary Swift app consume the SDK, given (a) a solo developer, (b) the wish to own the application architecture, (c) the need to replace the binding layer if it proves insufficient?

## Considered alternatives
1. **Prebuilt upstream `MatrixRustSDK` package (matrix-rust-components-swift), behind a Halo adapter** — later built from source at a pinned rev.
2. Own Rust crate depending on `matrix-sdk-ffi` and extending its objects (the earlier plan D3/D27).
3. Own UniFFI bindings over `matrix-sdk`/`matrix-sdk-ui` from day one.
4. Fork matrix-rust-sdk.
5. The deprecated Objective-C/Swift `matrix-ios-sdk`, or a native Swift implementation.

## Decision
Option 1 now, with option 3 as the planned fallback behind the same ports (ADR-0004), decided at gate G-FFI.

## Rationale
- Option 2 is **not possible**: the wrapped SDK objects in `matrix-sdk-ffi` are `pub(crate)` **[VERIFIED F-FFI-3]**, so another crate can't extend `Client`, `Timeline` or `SyncService`.
- Option 1 needs no Rust toolchain, uses the same bindings Element ships (well exercised), is Apache-2.0 **[VERIFIED F-LIC-4]**, and covers everything the MVP needs according to the API survey **[VERIFIED F-FFI-4..16]**, except the custom room state needed by stickers (V-ST-1, which has a workaround).
- Option 3 costs months before the first message — wrong for M0–M3, right if the upstream API proves insufficient.
- Option 4 adds permanent rebase costs; option 5 has no sliding sync / no maintained E2EE.

## Trade-offs
Halo depends on an API designed for Element X that changes often; some internals (event-cache gaps, required state) aren't reachable; a prebuilt binary is a supply-chain trust decision until built from source.

## Consequences
- Only `HaloMatrixAdapter` imports `MatrixRustSDK` (MODULE_BOUNDARIES).
- Pin exact version + checksum; record the matching SDK commit (V-SDK-1); build from source before external testers ([../matrix/SDK_INTEGRATION.md](../matrix/SDK_INTEGRATION.md) §1, Q-SDK-BUILD).
- G-FFI criteria: (a) unread scenarios pass using upstream data only; (b) sticker state loading solved within the port; (c) NSE within budget. Any failure → schedule option 3.

## Verified facts and assumptions
F-FFI-1..17, F-LIC-1..4 [VERIFIED]. V-SDK-1 [ASSUMPTION: the prebuilt version maps to an identifiable upstream commit].
