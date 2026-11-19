# ADR-0011: Stickers on spec image packs (Matrix v1.19)

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D12 (superseded), D13, D48 · **Validation:** V-ST-1, V-ST-2, V-ST-3

## Context
Image packs became part of the Matrix spec in v1.19: `m.room.image_pack` state and `m.image_pack.rooms` account data **[VERIFIED F-SPEC-3]**; ruma at the pinned SDK rev has the stable types **[VERIFIED F-SDK-2]**. The earlier plan used unstable `im.ponies.*` and personal packs in account data.

## Problem
Which representation gives Discord-like stickers that work across Matrix clients?

## Considered alternatives
1. **Spec image packs; personal packs = a private room; read legacy `im.ponies.*` read-only.**
2. Write both stable and legacy formats.
3. Legacy `im.ponies.*` only.
4. A Halo-proprietary format.

## Decision
Option 1 ([../features/STICKERS.md](../features/STICKERS.md)).

## Rationale
Spec-compliant and future-proof; `m.sticker` sending is universally rendered. Dual-writing doubles failure modes; proprietary breaks interop.

## Trade-offs
Clients that only know `im.ponies.*` won't see Halo-created packs (stickers themselves still render everywhere). Packs are unencrypted (spec) → user notice. Loading pack state through the FFI is unproven (V-ST-1).

## Consequences
`RoomPort.state` with a fallback authenticated GET inside the adapter; Halo account data for favourites/recents.

## Verified facts and assumptions
F-SPEC-3, F-SDK-2, F-FFI-9 [VERIFIED]; V-ST-1/2/3 [ASSUMPTION/OPEN].
