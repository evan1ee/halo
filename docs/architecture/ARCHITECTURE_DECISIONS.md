# Architecture Decisions — Index

Full records are in [../adr/](../adr/README.md). Product-level decisions are in [../DECISION_LOG.md](../DECISION_LOG.md).

| ADR | Title | Status |
|---|---|---|
| [0001](../adr/0001-monorepo.md) | Monorepo | Accepted |
| [0002](../adr/0002-matrix-sdk-integration.md) | Integrate matrix-rust-sdk via the upstream FFI binary, behind an adapter | Accepted |
| [0003](../adr/0003-ffi-technology.md) | UniFFI (not a hand-written C ABI) for any Halo-owned FFI | Accepted |
| [0004](../adr/0004-ports-and-adapter-boundary.md) | Halo-owned ports as the stable Swift ⇄ Matrix contract | Accepted |
| [0005](../adr/0005-swiftui-state-management.md) | `@Observable` view models + coordinators; no TCA | Accepted |
| [0006](../adr/0006-persistence.md) | GRDB SQLite in the App Group for app-owned data | Accepted (validation V-SQL-1/2) |
| [0007](../adr/0007-unread-source-of-truth.md) | Read-state source of truth and reconciliation policy | Accepted (gate G-UNREAD) |
| [0008](../adr/0008-feature-module-boundaries.md) | Local Swift packages per layer and per feature | Accepted |
| [0009](../adr/0009-testing-infrastructure.md) | Testing infrastructure | Accepted |
| [0010](../adr/0010-push-pipeline.md) | Push via Sygnal `event_id_only` + NSE | Accepted (validation V-NSE-*) |
| [0011](../adr/0011-stickers-image-packs.md) | Stickers on spec image packs (v1.19) | Accepted (validation V-ST-1) |
| [0012](../adr/0012-bot-integration.md) | Bot integration without bot changes | Accepted |
| [0013](../adr/0013-clean-room-and-licensing.md) | Clean-room development and licence gate | Accepted |
| [0014](../adr/0014-minimum-ios-26.md) | Minimum iOS 26 | Accepted |
