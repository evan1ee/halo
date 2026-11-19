# CI/CD

Decision: D36 (Linux CI for everything that can run on Linux; Apple builds on the founder's Mac). Platform: GitHub Actions on the private repository.

## 1. Pipelines

| Workflow | Trigger | Runner | Steps | Status |
|---|---|---|---|---|
| `docs.yml` | PR, push to main | ubuntu | `scripts/validate-docs.sh` | **Phase 0** (script exists) |
| `swift-linux.yml` | PR | ubuntu + Docker `swift` image | build + test `HaloFoundation`, `HaloDomain`, `HaloApplication`, `HaloPersistence`, `HaloTestSupport` | M0 |
| `boundaries.yml` | PR | ubuntu | `scripts/check-boundaries.sh` (forbidden imports, upstream types in public API) | M0 |
| `scenarios.yml` | PR touching read state / nightly | ubuntu + Docker Compose (`infra/test`) | start Synapse → `tools/scenario-driver` S01–S21 + feature scenarios | M3 |
| `secrets.yml` | PR | ubuntu | gitleaks | M0 |
| `licenses.yml` | PR touching `Package.resolved`, `ios/SDKVERSION.md` or `core/` | ubuntu (+ Rust) | inventory for the pinned SDK commit, allowlist check, diff report | M0 |

macOS runners aren't used by default (cost on private repos). Optional manual `ios-build.yml` (workflow_dispatch) on `macos-latest` for release candidates **[OPEN Q-CI-MAC]**.

## 2. Local validation (pre-push script `scripts/prepush.sh`, M0)
SwiftLint → boundaries → docs validation → Linux-compatible package tests (`swift test`) → for adapter changes: the simulator FFI smoke + contract tests.

## 3. Required checks on `main`
`docs`, `swift-linux`, `boundaries`, `secrets`, and `scenarios` (when applicable). A PR can't merge with failing required checks once branch protection is enabled (collaborators phase).

## 4. Delivery
No automatic TestFlight upload in the personal phase; the release checklist (BUILD_AND_RELEASE §4) is run locally. Revisit with Xcode Cloud or a macOS runner when external testers join.
