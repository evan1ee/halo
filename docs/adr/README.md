# Architecture Decision Records

Format: [TEMPLATE.md](TEMPLATE.md). Numbering is sequential and never reused. An accepted ADR is changed only by a new ADR that supersedes it.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-monorepo.md) | Monorepo | Accepted |
| [0002](0002-matrix-sdk-integration.md) | matrix-rust-sdk via the upstream FFI binary, behind an adapter | Accepted (gate G-FFI) |
| [0003](0003-ffi-technology.md) | UniFFI for any Halo-owned FFI | Accepted |
| [0004](0004-ports-and-adapter-boundary.md) | Halo-owned ports as the stable contract | Accepted |
| [0005](0005-swiftui-state-management.md) | `@Observable` view models + coordinators | Accepted |
| [0006](0006-persistence.md) | GRDB SQLite in the App Group | Accepted (V-SQL-1/2) |
| [0007](0007-unread-source-of-truth.md) | Read-state source of truth and reconciliation | Accepted (gate G-UNREAD) |
| [0008](0008-feature-module-boundaries.md) | Local Swift packages per layer and feature | Accepted |
| [0009](0009-testing-infrastructure.md) | Testing infrastructure | Accepted |
| [0010](0010-push-pipeline.md) | Push via Sygnal + NSE | Accepted (V-NSE, V-PUSH) |
| [0011](0011-stickers-image-packs.md) | Stickers on spec image packs | Accepted (V-ST-1..3) |
| [0012](0012-bot-integration.md) | Bot integration without bot changes | Accepted |
| [0013](0013-clean-room-and-licensing.md) | Clean-room development and licence gate | Accepted |
| [0014](0014-minimum-ios-26.md) | Minimum iOS 26 | Accepted |
