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
| [0015](0015-count-only-pushes.md) | Count-only pushes must not set the app badge | Accepted with conditions (V-PUSH-5) |
| [0016](0016-nse-budget-gate.md) | Treat the NSE budget as its own gate (G-NSE) | Accepted (AC-NSE-1…6) |
| [0017](0017-xcodegen-for-the-app-project.md) | XcodeGen generates the app project | Accepted |
| [0018](0018-devices-list-over-direct-http.md) | List the account's sessions with one direct HTTP call | Accepted |
| [0019](0019-change-password-over-direct-http.md) | Change the password with one direct HTTP call | Accepted |
| [0020](0020-identity-read-order.md) | Order read state by event identity and timeline order, not timestamps | Accepted |
| [0021](0021-unread-message-count-badge.md) | App icon badge shows total unread message count across rooms needing attention | Accepted |
| [0022](0022-module-layout-v2.md) | Module and folder layout v2 (two manifests, files in their owning layer) | Proposed |
