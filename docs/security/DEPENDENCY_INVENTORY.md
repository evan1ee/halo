# Dependency Inventory

Every dependency that ships in, or builds, the app is listed here. Adding one requires a row **before** the code change (AGENTS.md §11).

## 1. Distributed with the app

| Dependency | Version (pinned) | Licence | Type | Justification | Verified |
|---|---|---|---|---|---|
| `element-hq/matrix-rust-components-swift` (product `MatrixRustSDK`, binary `MatrixSDKFFI.xcframework`) | `26.11.17` (exact + checksum) | Apache-2.0 | Prebuilt dynamic framework | Matrix protocol, E2EE, sync (ADR-0002) | F-LIC-4 |
| └ Rust crates inside it (matrix-sdk-*, ruma, vodozemac, uniffi, tokio, rustls, aws-lc, sqlite, tantivy, sentry …) | per SDK commit | see CSV (564 crates) | Linked into the framework | — | F-LIC-2, [inventory CSV](inventory/rust-deps-matrix-sdk-ffi.csv) |
| `groue/GRDB.swift` | `7.12.0` (exact) | MIT | SwiftPM source | App-owned database (ADR-0006) | F-LIC-5 |

## 2. Build/test only (not distributed)

None is added yet; each gets its exact version pinned in this table when it's introduced (M0), per AGENTS.md §11 (4).

| Dependency | Licence | Purpose |
|---|---|---|
| `pointfreeco/swift-snapshot-testing` | MIT **[VERIFIED F-LIC-7]** | Snapshot tests |
| SwiftLint | MIT **[VERIFIED F-LIC-7]** | Lint |
| gitleaks | MIT **[VERIFIED F-LIC-7]** | Secret scanning |
| cargo-deny, cargo-about (only if building the SDK or `core/`) | MIT OR Apache-2.0 **[VERIFIED F-LIC-7]** | Licence gate, notices |
| Docker images: Synapse, MAS, Sygnal, Postgres | AGPL-3.0 / AGPL-3.0 / Apache-2.0 **[VERIFIED F-LIC-8]** / PostgreSQL | Dev and test infrastructure (not distributed). Sygnal is extended by Halo's pushkin in `infra/sygnal/` (ADR-0015), server-side only |

## 3. Apple frameworks used
SwiftUI, Observation, Foundation, UserNotifications, BackgroundTasks, PhotosUI, AVKit, ImageIO, CryptoKit, Security (Keychain), AuthenticationServices, Intents (communication notifications), MetricKit, OSLog.

## 4. Explicitly rejected
| Dependency | Reason |
|---|---|
| Element X iOS code, assets, strings | AGPL-3.0 (ADR-0013) |
| lottie-ios | Not needed (D13) |
| TCA | ADR-0005 |
| Realm, SQLCipher | ADR-0006 |
| Any analytics / crash SaaS SDK | Privacy principle (revisit Q-CRASH before public release) |

## 5. Inventory regeneration
`cargo metadata --format-version 1 --filter-platform aarch64-apple-ios --features sentry --manifest-path bindings/matrix-sdk-ffi/Cargo.toml`
on the SDK commit that matches the shipped package, then walk normal+build dependencies from `matrix-sdk-ffi` (the walk used for F-LIC-2; a script
`scripts/rust-license-inventory.py` will be added in M0).
