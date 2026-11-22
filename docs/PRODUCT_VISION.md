# Product Vision

## Vision

Halo is a Matrix client for iOS that people can **trust**: the unread badge is never wrong, and
messages and state never drift. On top of that base it adds a sticker experience as good as
Discord's and native, structured rendering of personal assistant bots.

## Goals

| # | Goal | Measured by |
|---|---|---|
| G1 | Read state is correct in all cases | Acceptance criteria AC-U* ([REQUIREMENTS.md](REQUIREMENTS.md)); zero unexplained auditor findings over a 7-day soak |
| G2 | Covers everyday messaging, so the founder can switch from Element X | MVP checklist in [ROADMAP.md](ROADMAP.md) |
| G3 | Sending a sticker takes ≤ 2 taps from the composer and stays compatible with other Matrix clients | AC-S* |
| G4 | Bot messages are clearer than plain text without any change to the bot | AC-B* |
| G5 | Proprietary codebase with a defensible licensing position | Licence gate green; clean-room record; legal review before public release |
| G6 | One part-time engineer can maintain it for years | Module boundaries respected; SDK bumps take ≤ 1 day |

## Non-goals (for now)

- A fork, rebrand or redistribution of Element X (D37).
- Our own Matrix protocol implementation or crypto (we use matrix-rust-sdk).
- Homeservers without native sliding sync (D4).
- Voice/video calls in the MVP (D43).
- An in-app LLM or AI backend (D18).
- Feature parity with Element X in every corner (e.g. spaces management, polls creation, location sharing, widgets) before the MVP.
- Android, macOS, iPad-optimised layouts (iPad runs the iPhone layout).

## Core principles

1. **Correctness before features.** A feature that can leave state inconsistent doesn't ship.
2. **One source of truth per fact.** Matrix state belongs to the server and its SDK replica; Halo only adds
   derived state and explicit user intent (e.g. a pending receipt). See [architecture/DATA_FLOW.md](architecture/DATA_FLOW.md).
3. **Interoperable by default.** Use spec-defined events (`m.sticker`, `m.room.image_pack`, `m.marked_unread`);
   Halo-only metadata is always optional and ignorable.
4. **Honest UI.** Never show a state the server hasn't confirmed as if it were confirmed (pending reactions, sending messages, uncertain counts).
5. **Private by design.** No third-party analytics; diagnostics stay on the device until the user exports them.
6. **Small surface area.** Few dependencies, few abstractions; each must justify itself.

## Intended user experience

- **Calm and quick.** The room list opens from cache instantly; nothing jumps.
- **Trustworthy indicators.** A dot or number means "you haven't seen something that matters". When
  Halo isn't sure of an exact count it shows a dot rather than a wrong number.
- **Delightful expression.** The sticker panel slides up from the composer; favourites and recents come first; animated stickers play smoothly.
- **Structured bots.** A todo list from your bot looks like a checklist; ticking an item shows "pending" until the bot confirms.
- **Feels like an Apple app (D84).** Navigation, gestures, materials, text and haptics behave the way Messages and Mail do, so
  nothing needs learning; the quality bar is the "Ship-ready definition" in [ROADMAP.md](ROADMAP.md).
- **Own visual identity.** Halo's design language ([design/DESIGN_SYSTEM.md](design/DESIGN_SYSTEM.md)) is its own and isn't derived from Element X.

## Target users

| Phase | Users | Infrastructure |
|---|---|---|
| Personal (months 0–12) | The founder + a small trusted circle (TestFlight) | Self-hosted Synapse + MAS + Sygnal |
| Public (year 2+) | Matrix power users on servers with sliding sync | Same push gateway, operated as a service; legal review done |
