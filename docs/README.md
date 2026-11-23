# Halo Documentation

Halo is an independent, proprietary Matrix client for iOS built with SwiftUI on top of the official
`matrix-rust-sdk`. This directory is the **single source of truth** for requirements, architecture
and engineering process. Code that contradicts these documents is a bug in either the code or
the document: fix one of them in the same change.

**Phase:** M0–M10 implemented (2026-11-22); next is the Apple-native UX and ship-readiness phase M11–M15 (D84, [ROADMAP.md](ROADMAP.md)). Phase 0 record: [PHASE0_REPORT.md](PHASE0_REPORT.md).

## Statement labels

Documents mark important statements with one of these labels:

| Label | Meaning |
|---|---|
| **[VERIFIED]** | Checked against a primary source (spec, SDK source at a pinned revision, licence file); the source is in [SOURCES.md](SOURCES.md) |
| **[DECISION]** | A design decision for this project, with an ID (Dnn / ADR-nnnn) |
| **[ASSUMPTION]** | Believed true but not yet verified; has a validation item `V-*` in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) |
| **[OPEN]** | Unresolved; listed in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) with options and the validation needed |

## Reading order

1. [PRODUCT_VISION.md](PRODUCT_VISION.md) → [REQUIREMENTS.md](REQUIREMENTS.md) → [ROADMAP.md](ROADMAP.md)
2. [architecture/OVERVIEW.md](architecture/OVERVIEW.md) → [architecture/MODULE_BOUNDARIES.md](architecture/MODULE_BOUNDARIES.md)
3. [matrix/UNREAD_STATE.md](matrix/UNREAD_STATE.md) (the most important subsystem)
4. The feature spec for whatever you are building, under `features/`
5. [../AGENTS.md](../AGENTS.md): the engineering contract

## Index

| Area | Documents |
|---|---|
| Product | [PRODUCT_VISION](PRODUCT_VISION.md) · [REQUIREMENTS](REQUIREMENTS.md) · [ROADMAP](ROADMAP.md) · [GLOSSARY](GLOSSARY.md) |
| Decisions | [DECISION_LOG](DECISION_LOG.md) · [adr/](adr/README.md) · [OPEN_QUESTIONS](OPEN_QUESTIONS.md) · [RISK_REGISTER](RISK_REGISTER.md) · [SOURCES](SOURCES.md) |
| Architecture | [OVERVIEW](architecture/OVERVIEW.md) · [SYSTEM_DESIGN](architecture/SYSTEM_DESIGN.md) · [MODULE_BOUNDARIES](architecture/MODULE_BOUNDARIES.md) · [DATA_FLOW](architecture/DATA_FLOW.md) · [CONCURRENCY](architecture/CONCURRENCY.md) · [ERROR_HANDLING](architecture/ERROR_HANDLING.md) · [BACKGROUND_EXECUTION](architecture/BACKGROUND_EXECUTION.md) · [LOGGING_AND_DIAGNOSTICS](architecture/LOGGING_AND_DIAGNOSTICS.md) · [ARCHITECTURE_DECISIONS](architecture/ARCHITECTURE_DECISIONS.md) |
| Matrix | [SDK_INTEGRATION](matrix/SDK_INTEGRATION.md) · [RUST_FFI](matrix/RUST_FFI.md) · [PORTS_CONTRACT](matrix/PORTS_CONTRACT.md) · [SYNC_ENGINE](matrix/SYNC_ENGINE.md) · [UNREAD_STATE](matrix/UNREAD_STATE.md) · [READ_RECEIPTS](matrix/READ_RECEIPTS.md) · [PUSH_NOTIFICATIONS](matrix/PUSH_NOTIFICATIONS.md) · [MEDIA](matrix/MEDIA.md) |
| Features | [_TEMPLATE](features/_TEMPLATE.md) · [AUTHENTICATION](features/AUTHENTICATION.md) · [ENCRYPTION_AND_DEVICES](features/ENCRYPTION_AND_DEVICES.md) · [ROOM_LIST](features/ROOM_LIST.md) · [TIMELINE](features/TIMELINE.md) · [MESSAGING](features/MESSAGING.md) · [MEDIA_ATTACHMENTS](features/MEDIA_ATTACHMENTS.md) · [NOTIFICATIONS](features/NOTIFICATIONS.md) · [ROOM_MANAGEMENT](features/ROOM_MANAGEMENT.md) · [USER_PROFILES](features/USER_PROFILES.md) · [STICKERS](features/STICKERS.md) · [COMPOSER_PANELS](features/COMPOSER_PANELS.md) · [BOT_MESSAGES](features/BOT_MESSAGES.md) · [BOT_ACTIVITY](features/BOT_ACTIVITY.md) · [SETTINGS](features/SETTINGS.md) |
| Design | [DESIGN_SYSTEM](design/DESIGN_SYSTEM.md) · [NAVIGATION](design/NAVIGATION.md) · [SCREEN_SPECIFICATIONS](design/SCREEN_SPECIFICATIONS.md) · [UX_AUDIT](design/UX_AUDIT.md) |
| Data | [DATA_MODELS](data/DATA_MODELS.md) · [PERSISTENCE](data/PERSISTENCE.md) · [MIGRATIONS](data/MIGRATIONS.md) |
| Security | [SECURITY](security/SECURITY.md) · [PRIVACY](security/PRIVACY.md) · [LICENSE_COMPLIANCE](security/LICENSE_COMPLIANCE.md) · [DEPENDENCY_INVENTORY](security/DEPENDENCY_INVENTORY.md) |
| Testing | [TEST_STRATEGY](testing/TEST_STRATEGY.md) · [UNREAD_REGRESSION_TESTS](testing/UNREAD_REGRESSION_TESTS.md) · [INTEGRATION_TESTS](testing/INTEGRATION_TESTS.md) |
| Development | [DEVELOPMENT_SETUP](development/DEVELOPMENT_SETUP.md) · [CODE_CONVENTIONS](development/CODE_CONVENTIONS.md) · [TECH_DEBT](development/TECH_DEBT.md) · [BUILD_AND_RELEASE](development/BUILD_AND_RELEASE.md) · [CI_CD](development/CI_CD.md) |

## Maintenance rules

- [../HANDOFF.md](../HANDOFF.md) (repository root) is updated in the last commit of every push (AGENTS.md §18). It summarises the
  state and links here; it never holds the only copy of a fact.

- Each fact appears in exactly one place; other documents link to it rather than restating it.
- A change in behaviour updates the owning document **in the same commit**.
- `scripts/validate-docs.sh` checks structure, links and labels; it runs in CI.
