# CI/CD

Decision: D36 (Linux CI for everything that can run on Linux; Apple builds on the founder's Mac). Platform: GitHub Actions on the private repository.

## 1. Pipelines

| Workflow | Trigger | Runner | Steps | Status |
|---|---|---|---|---|
| `docs.yml` | PR, push to main | ubuntu | `scripts/validate-docs.sh` | **Phase 0** (script exists) |
| `swift-linux.yml` | PR | ubuntu + Docker `swift` image | build + test (warnings as errors) `HaloFoundation`, `HaloDomain`, `HaloTestSupport`, `HaloApplication`; `HaloPersistence` joins with its first table (M3) | **M0 (in place)** |
| `boundaries.yml` | PR | ubuntu | `scripts/check-boundaries.sh` (forbidden imports, upstream types in public API) | **M0 (in place)** |
| `scenarios.yml` | PR touching read state / nightly | ubuntu + Docker Compose (`infra/test`) | start Synapse → `tools/scenario-driver` S01–S22 + feature scenarios | M3 |
| `secrets.yml` | PR | ubuntu | gitleaks 8.30.1, pinned by checksum, over the full history | **M0 (in place)** |
| `pushkin.yml` | PR touching `infra/sygnal/` or the pinned Sygnal version | ubuntu + Python | pushkin unit tests over Synapse notification fixtures: count-only → background push; **no payload contains `aps.badge`**; no counts in event payloads (ADR-0015) | M1 |
| `licenses.yml` | PR touching `Package.resolved`, `ios/SDKVERSION.md` or `core/` | ubuntu (+ Rust) | check out `sdk_commit` from `ios/SDKVERSION.md`, `scripts/rust-license-inventory.py --check` (inventory diff + allowlist) | **M0 (in place)** |

macOS runners aren't used by default (cost on private repos). Optional manual `ios-build.yml` (workflow_dispatch) on `macos-latest` for release candidates **[OPEN Q-CI-MAC]**.

## 2. Local validation (`scripts/prepush.sh`, in place since M0)
Docs validation → boundaries → package tests (local `swift`, or the `swift:6.2-noble` Docker image) → gitleaks → SwiftLint (once
`.swiftlint.yml` exists). Steps whose tool is missing are listed as SKIPPED, never reported as passed. For adapter changes (M0b): the
simulator FFI smoke + contract tests.

The workflows run on pull requests and on pushes to `main`; work branches get CI results once a pull request is open.

## 3. Required checks on `main`
`docs`, `swift-linux`, `boundaries`, `secrets`, and `scenarios` (when applicable). A PR can't merge with failing required checks once branch protection is enabled (collaborators phase).

## 4. Delivery
No automatic TestFlight upload in the personal phase; the release checklist (BUILD_AND_RELEASE §4) is run locally. Revisit with Xcode Cloud or a macOS runner when external testers join.
