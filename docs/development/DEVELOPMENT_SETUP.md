# Development Setup

> Applies from M0. Nothing in this document is implemented yet; it's the specification of the setup to build.

## 1. Repository layout (target)

```
halo/
├── AGENTS.md                 engineering contract (read first)
├── CLAUDE.md                 pointer to AGENTS.md for Claude Code
├── README.md · CONTRIBUTING.md · LICENSE · .gitignore
├── docs/                     all documentation (this tree)
├── ios/
│   ├── Halo.xcodeproj        app + NSE targets only (composition roots)
│   ├── App/                  Halo app target sources (AppContainer, scenes, Info.plist, entitlements)
│   ├── NotificationService/  NSE target sources
│   ├── Config/               xcconfig files (Base, Debug, Release, per-environment)
│   ├── SDKVERSION.md         pinned SDK package version ↔ upstream commit
│   └── Packages/
│       ├── HaloFoundation/  HaloDomain/  HaloApplication/
│       ├── HaloMatrixAdapter/  HaloPersistence/  HaloPlatform/
│       ├── HaloDesignSystem/  HaloBotRendering/  HaloTestSupport/
│       └── Features/ (FeatureAuth, FeatureRoomList, FeatureTimeline, FeatureComposer,
│                      FeatureRoomDetails, FeatureProfile, FeatureSettings, FeatureStickers, FeatureBotActivity)
├── tools/
│   └── scenario-driver/      Swift (Linux) CLI driving Synapse for scenario tests
├── infra/
│   ├── dev/                  docker-compose: Synapse (native password login) + Postgres + Sygnal; MAS added in M5 (D64) (+ .env.example)
│   ├── sygnal/               Halo's Sygnal pushkin + tests (ADR-0015), mounted into the pinned Sygnal image
│   └── test/                 docker-compose for CI scenarios (+ fault-injection proxy)
├── scripts/                  validate-docs.sh, check-boundaries.sh, rust-license-inventory.py, notices generator
├── core/                     (only if gate G-FFI fails) Rust workspace for halo-ffi
└── .github/workflows/        CI (see CI_CD.md)
```

Each package is a separate `Package.swift` (local package), referenced by the Xcode project. Responsibilities and allowed
dependencies: [../architecture/MODULE_BOUNDARIES.md](../architecture/MODULE_BOUNDARIES.md).

## 2. Prerequisites
| Tool | Version | Note |
|---|---|---|
| macOS + Xcode | Xcode with the iOS 26 SDK (D25) | Swift 6 language mode |
| Docker Desktop / Colima | current | `infra/dev`, `infra/test` |
| Swift toolchain on Linux (CI) | same Swift minor as Xcode — `swift:6.2-noble` (Swift 6.2.4) is the floor; local Xcode 27.2 has Swift 6.4.2 and both pass (V-CI-2) | Docker image |
| Rust (rustup) | ≥ 1.96 (SDK `rust-version`, F-FFI-17 context) | Only for building the SDK from source or `core/` |
| SwiftLint | pinned in `.swiftlint.yml` comment | Lint |
| gitleaks | current | Pre-commit + CI |

## 3. Xcode project configuration
- Targets: `Halo` (iOS app), `HaloNotificationService` (NSE). Deployment target iOS 26.0.
- Capabilities (both targets): App Groups `group.one.mbm.halo`, Keychain Sharing `<TeamID>.one.mbm.halo.shared` (identifiers below); app: Push Notifications, Background Modes (remote notifications, background fetch), Communication Notifications; NSE: the filtering entitlement once granted (V-PUSH-3).
- Build configurations: `Debug` (dev Synapse, verbose logs, auditor on), `Beta` (TestFlight: auditor on, logs info), `Release` (auditor off unless enabled in Diagnostics).
- Settings in `ios/Config/*.xcconfig`: bundle IDs, App Group, default homeserver, Sygnal app id, log level. No secrets. `N` is defined once
  (`HALO_NAMESPACE = one.mbm.halo` in `Base.xcconfig`) and every other identifier is derived from it, so the app and its extensions can't diverge.

### Identifiers (D63)
`N` = the project-owned namespace root, reverse-DNS of a domain the founder controls. **Value: `one.mbm.halo`** (founder,
2026-11-19). This table is the one place the identifiers are defined; changing `N` later means new bundle IDs and new account-data
types, so it is treated as fixed.

| Identifier | Value |
|---|---|
| App bundle ID | `one.mbm.halo` |
| NSE bundle ID | `one.mbm.halo.nse` (future extensions: `one.mbm.halo.<extension>`) |
| App Group | `group.one.mbm.halo` |
| Keychain access group | `<TeamID>.one.mbm.halo.shared` |
| BG task identifier | `one.mbm.halo.refresh` |
| Log subsystem | `one.mbm.halo` |
| Darwin notification (DB changed) | `one.mbm.halo.db.changed` |
| Sygnal / pusher `app_id` | `one.mbm.halo` (production APNs), `one.mbm.halo.dev` (sandbox) |
| Halo account-data types | `one.mbm.halo.sticker_prefs`, `one.mbm.halo.sticker_rooms`, `one.mbm.halo.bot_allowlist` |
- Swift settings: `SWIFT_VERSION = 6`, strict concurrency `complete`, warnings as errors in CI.

## 4. Environments
| Name | Homeserver | Push | Used by |
|---|---|---|---|
| local | `infra/dev` on localhost (via the Mac's LAN IP for devices) | Sygnal → APNs sandbox | Development |
| test | `infra/test` ephemeral | none (pipeline called directly) | CI |
| personal | Founder's production Synapse | Sygnal → APNs production | Beta/Release |

## 5. Local workflow
1. `docker compose -f infra/dev/docker-compose.yml up -d`, then `infra/dev/smoke.sh` and `infra/dev/create-user.sh <name>` ([../../infra/dev/README.md](../../infra/dev/README.md))
2. Open `ios/Halo.xcodeproj`, scheme `Halo-Debug`, run on the simulator (push needs a device).
3. Fast loop for logic: `swift test --package-path ios/Packages/HaloDomain` (also runs on Linux).
4. Before pushing: `scripts/validate-docs.sh`, `scripts/check-boundaries.sh`, SwiftLint, unit tests.

## 6. Dependency management
SwiftPM only. Versions pinned **exactly** (`exact:`) and `Package.resolved` committed. Adding/upgrading a dependency follows AGENTS.md §11.
