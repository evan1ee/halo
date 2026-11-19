# Halo — Development Plan

## 1. Repository structure (D42)

```
halo/                         (private, proprietary)
  LICENSE                     All rights reserved
  CONTRIBUTING.md             clean-room policy, licence rules, commit conventions
  core/                       Rust workspace (see architecture §3)
    deny.toml                 cargo-deny licence gate
  ios/                        Xcode project + local Swift packages (architecture §4)
  infra/
    dev/docker-compose.yml    Synapse (sliding sync) + Postgres + MAS + Sygnal (dev)
    test/                     ephemeral Synapse config for scenario tests
    prod/                     your homeserver deployment notes (no secrets)
  scripts/
    build-xcframework.sh      cargo build for aarch64-apple-ios + aarch64-apple-ios-sim → uniffi-bindgen (library mode) → xcodebuild -create-xcframework
    licenses.sh               cargo-about → THIRD_PARTY_NOTICES + in-app plist
  docs/
    decisions.md  01..07-*.md  licensing/  reference-notes/
```

## 2. Module implementation order

1. `infra/dev` — a working Synapse with sliding sync and a test account (everything depends on it).
2. `core/halo-ffi` skeleton depending on `matrix-sdk-ffi` → **spike T1**: one Swift call into the
   upstream FFI and one into a Halo UniFFI object from the same XCFramework.
3. `ios` app shell + `HaloKit.SessionService` (login, restore) + NSE target linking the same framework.
4. Room list → timeline (read-only) → E2EE verification and recovery.
5. NSE notification spike (measure memory and time on a device).
6. Composer and messaging features; media display; image send.
7. `halo-store` (SQLCipher, migrations, cross-process lock) → `halo-unread` (pure) → wiring
   (visibility tracker, outbox, badge, clearing) → `halo-testkit` scenarios → auditor.
8. `halo-stickers` + Stickers feature UI.
9. Hardening (MAS/OIDC, settings, acknowledgements, generic bot rendering, performance).
10. Post-MVP per the roadmap.

## 3. Development workflow

- Trunk-based on `main`; short feature branches; squash merges. Conventional commit prefixes
  (`core:`, `ios:`, `infra:`, `docs:`).
- Every behaviour decision → a `docs/decisions.md` entry (Dnn). Architecture changes → update doc 02.
- Learning from Element X → prose notes in `docs/reference-notes/` from **using the app** (D37).
- AI-assisted coding: specs and tests first; review all generated code; no AGPL code in prompts.
- SDK bump routine (at most monthly): branch → bump the rev → `cargo deny check` → regenerate the inventory →
  build the XCFramework → fix Swift → run the scenario suite → merge.

## 4. Testing and CI/CD (D35, D36)

| Layer | Tooling | Where |
|---|---|---|
| Rust unit + property tests | `cargo test`, proptest | GitHub Actions, Linux, every PR |
| Licence gate | `cargo deny check licenses bans sources` | GitHub Actions, every PR |
| Synapse scenario tests | docker compose + `halo-testkit` | GitHub Actions, Linux, every PR touching `core/` (nightly full) |
| Sync replay regression | fixtures in `core/halo-testkit/fixtures` | with the unit tests |
| Swift unit / view-model / renderer fixtures | XCTest / Swift Testing | Local Mac (pre-push script) |
| Snapshot tests (cards, sticker panel) | swift-snapshot-testing (test-only) | Local Mac |
| UI smoke | XCUITest against the dev Synapse | Local Mac, before TestFlight |
| On-device auditor | built into debug and TestFlight builds | Real use |

Note: iOS targets can't build on Linux; `halo-ffi` gets a `cargo check` for
`aarch64-apple-ios` on a macOS runner only before releases (to keep costs down), and on every local build.

## 5. Release strategy

- **Channels:** Debug (dev Synapse) → Internal TestFlight (you) → External TestFlight (small circle,
  needs Apple beta review) → App Store (only after M10 and the legal review).
- **Versioning:** `YEAR.MINOR.PATCH` for the app; record the pinned SDK rev in each release's notes.
- **Release checklist:** CI green; scenario suite green; auditor soak passed on the
  previous build; licence inventory regenerated and the acknowledgements updated; export-compliance flag set;
  DB migration tested from the last released schema; push and NSE manual checks (doc 05 §8.5).
- **Rollback:** TestFlight build expiry/replacement; DB migrations are forward-only, and we can always rebuild `halo.sqlite`
  from the SDK and the server (doc 02 §5).
- **Apple prerequisites (start in M1):** an App ID with the App Group, Keychain sharing, Push Notifications,
  the NSE; request `com.apple.developer.usernotifications.filtering`; an APNs auth key for Sygnal.
