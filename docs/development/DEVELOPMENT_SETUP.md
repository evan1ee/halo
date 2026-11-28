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
│       ├── HaloCore/         Linux-buildable manifest (HaloFoundation, HaloDomain, HaloApplication, HaloTestSupport)
│       └── HaloApple/        Apple manifest (HaloMatrixAdapter, HaloPersistence, HaloPlatform, HaloDesignSystem,
│                             HaloBotRendering, FeatureOnboarding, FeatureRoomList, FeatureTimeline,
│                             FeatureMedia, FeatureRoomDetails, FeatureProfile, FeatureSearch, FeatureSettings,
│                             FeatureStickers, FeatureBotActivity)
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

Two local SwiftPM manifests (`HaloCore` and `HaloApple`, ADR-0022 / D86) are referenced by the Xcode project, with one
Swift target per module. Responsibilities and allowed dependencies: [../architecture/MODULE_BOUNDARIES.md](../architecture/MODULE_BOUNDARIES.md).

## 2. Prerequisites
| Tool | Version | Note |
|---|---|---|
| macOS + Xcode | Xcode with the iOS 26 SDK (D25) | Swift 6 language mode |
| Docker Desktop / Colima | current | `infra/dev`, `infra/test`, the scale fixture |
| Swift toolchain on Linux (CI) | same Swift minor as Xcode — `swift:6.2-noble` (Swift 6.2.4) is the floor; local Xcode 27.2 has Swift 6.4.2 and both pass (V-CI-2) | Docker image |
| Rust (rustup) | ≥ 1.96 (SDK `rust-version`, F-FFI-17 context) | Only for building the SDK from source or `core/` |
| SwiftLint | pinned in `.swiftlint.yml` comment | Lint |
| gitleaks | current | Pre-commit + CI |

## 3. Xcode project configuration
- Targets: `Halo` (iOS app), `HaloNotificationService` (NSE). Deployment target iOS 26.0.
- Capabilities (both targets): App Groups `group.one.mbm.halo`, Keychain Sharing `<TeamID>.one.mbm.halo.shared` (identifiers below); app: Push Notifications, Background Modes (remote notifications, background fetch), Communication Notifications; NSE: the filtering entitlement once granted (V-PUSH-3).
- Build configurations: `Debug` (dev Synapse, verbose logs, auditor on), `Beta` (TestFlight: auditor on, logs info), `Release` (auditor off unless enabled in Diagnostics).
- `ios/Halo.xcodeproj` is generated from `ios/project.yml` (ADR-0017): edit the spec, then `brew install xcodegen` (once) and `cd ios && xcodegen --spec project.yml --project .`; commit both. Debug builds allow plain http to local-network addresses (`ios/App/Info-Debug.plist`) so a physical device can reach `infra/dev` started with `HALO_DEV_BIND=0.0.0.0` (enter `http://<mac-ip>:8008` as the server). The development team isn't in the spec: copy `ios/Config/Local.xcconfig.example` to `ios/Config/Local.xcconfig` (git-ignored, included by `Base.xcconfig` when present) and set your `DEVELOPMENT_TEAM`, so it survives regenerating or reverting the project; picking the team in Xcode instead writes it into `project.pbxproj`, which must not be committed.
- Simulator builds without a team need an ad-hoc signature, otherwise the Keychain fails with -34018: `xcodebuild -project ios/Halo.xcodeproj -scheme Halo-Debug -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO build`.
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
| test | `infra/test/run.sh`, ephemeral | none (pipeline called directly) | CI |
| personal | Founder's production Synapse | Sygnal → APNs production | Beta/Release |

## 5. Local workflow
1. `docker compose -f infra/dev/docker-compose.yml up -d`, then `infra/dev/smoke.sh` and `infra/dev/create-user.sh <name>` ([../../infra/dev/README.md](../../infra/dev/README.md))
2. Open `ios/Halo.xcodeproj`, scheme `Halo-Debug`, run on the simulator (push needs a device).
3. Fast loop for logic: `swift test --package-path ios/Packages/HaloCore` (also runs on Linux).
4. Before pushing: `scripts/validate-docs.sh`, `scripts/check-boundaries.sh`, SwiftLint, unit tests.

## 6. Dependency management
SwiftPM only. If `git clone` of GRDB's full history stalls, make a shallow bare mirror of the tag (`git clone --bare --depth 1 --branch v7.12.0 https://github.com/groue/GRDB.swift /tmp/grdb-mirror.git`) and point SwiftPM at it with a *user-level* `~/.swiftpm/configuration/mirrors.json` (`original`: the GRDB URL, `mirror`: `file:///tmp/grdb-mirror.git`); manifests and `Package.resolved` keep the public URL and the exact pin. Versions pinned **exactly** (`exact:`) and `Package.resolved` committed. Adding/upgrading a dependency follows AGENTS.md §11.
