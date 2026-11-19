# Contributing to Halo

Halo is proprietary software (see LICENSE). These rules protect its independent authorship.

## Clean-room policy (D37)
- Element X (iOS/Android/Web) is licensed AGPL-3.0. Do not read its source while working on Halo,
  and never copy its code, strings, assets, icons, or layouts.
- Allowed references: the Matrix specification and MSCs; matrix-rust-sdk (Apache-2.0) code and docs;
  behaviour observed by using Element X or other clients; public talks and blog posts.
- Record learnings as prose in `docs/reference-notes/` (behaviour and protocol only, no code).
- Do not import code from the earlier personal Element X fork.
- Do not paste AGPL/GPL code into AI assistants. Review all AI-generated code before committing.

## Dependencies (D39)
- New Rust crates must pass `cargo deny check` (see `core/deny.toml`); GPL/LGPL/AGPL are blocked.
- New Swift packages need an entry in `docs/03-Licensing-Dependency-Strategy.md` §4.2 and review.
- Copying permissive third-party code requires a header comment naming source, licence and copyright,
  and an entry in THIRD_PARTY_NOTICES.
- Never vendor or modify MPL-2.0 files (e.g. UniFFI).

## Decisions
- Product/architecture decisions are recorded in `docs/decisions.md` with an ID (Dnn).
