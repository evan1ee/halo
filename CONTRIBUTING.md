# Contributing to Halo

Halo is proprietary software (see [LICENSE](LICENSE)). Read [AGENTS.md](AGENTS.md) first — it is the binding engineering contract.
The rules below protect Halo's independent authorship (ADR-0013).

## Clean-room policy (D37)
- Element X (iOS/Android/Web) is licensed AGPL-3.0. Don't read its source while working on Halo,
  and never copy its code, strings, assets, icons or layouts.
- Allowed references: the Matrix specification and MSCs; matrix-rust-sdk (Apache-2.0) code and docs;
  behaviour observed by using Element X or other clients; public talks and blog posts.
- Record learnings as prose in `docs/reference-notes/` (behaviour and protocol only, no code).
- Don't import code from the earlier personal Element X fork.
- Don't paste AGPL/GPL code into AI assistants. Review all AI-generated code before committing.

## Dependencies (D39)
- Follow AGENTS.md §11. Every dependency needs a row in [docs/security/DEPENDENCY_INVENTORY.md](docs/security/DEPENDENCY_INVENTORY.md)
  with a verified licence; GPL/LGPL/AGPL/SSPL/BUSL are not allowed.
- Copying permissive third-party code requires a header comment naming the source, licence and copyright,
  and an entry in THIRD_PARTY_NOTICES.
- Never vendor or modify MPL-2.0 files (e.g. UniFFI).

## Decisions
- Product decisions: [docs/DECISION_LOG.md](docs/DECISION_LOG.md) (Dnn). Architectural decisions: [docs/adr/](docs/adr/README.md).

## Workflow
Branching, commits and checks: [docs/development/CODE_CONVENTIONS.md](docs/development/CODE_CONVENTIONS.md) §5 and [docs/development/CI_CD.md](docs/development/CI_CD.md).
