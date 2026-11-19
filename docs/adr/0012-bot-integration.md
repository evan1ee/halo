# ADR-0012: Bot integration without bot changes

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** D18–D23, D26 · **Validation:** fixtures from the bot repo

## Context
The founder's bot (evan1ee/matrix-bot, MIT) is a normal Matrix user and must remain unchanged; it sends `body` + an HTML subset and understands specific reactions on specific messages **[VERIFIED F-BOT-1..4]**.

## Problem
How to give bot messages native UI and interactions without a bot API?

## Considered alternatives
1. **Client-side recognition (strict versioned parsers for allowlisted senders) + existing reaction protocol + a derived local index.**
2. Change the bot to emit structured content (rejected by D18 for now; possible later as an optional, backward-compatible field, D21).
3. Heuristic parsing of any message (unreliable).

## Decision
Option 1 ([../features/BOT_MESSAGES.md](../features/BOT_MESSAGES.md), [../features/BOT_ACTIVITY.md](../features/BOT_ACTIVITY.md)).

## Rationale
No server changes, honest UI (pending until the bot confirms), graceful fallback.

## Trade-offs
Parsers break when the bot's wording changes (fallback protects the UI); the index can be incomplete (labelled "from messages on this device"); only task owners can complete tasks (Q-BOT-OWNER).

## Consequences
Fixture sync from the bot repo whenever the bot changes; diagnostics count unparsed bot messages.

## Verified facts and assumptions
F-BOT-1..4 [VERIFIED from the bot's source].
