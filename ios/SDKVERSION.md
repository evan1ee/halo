# Pinned Matrix SDK

The machine-readable lines below are read by `.github/workflows/licenses.yml`; keep the `key: value` format.

package: element-hq/matrix-rust-components-swift
package_version: 26.11.17
package_checksum: d4d202da0623b7637664211612b5ac9a5c5fe797b849e29a66922e41e1ee6263
sdk_repository: https://github.com/matrix-org/matrix-rust-sdk
sdk_commit: b93751e93da6949a6a8ef8ff0b2c1c8faacaf677
sdk_features: sentry
sdk_profile: small-release-stripped

## How the mapping is known (V-SDK-1)
Each release commit of `matrix-rust-components-swift` names the SDK commit it was built from; for `26.11.17` it is
`Bump to version 26.11.17 (matrix-rust-sdk/main b93751e93da6949a6a8ef8ff0b2c1c8faacaf677)`. The release script
(`Tools/Release/Sources/Release.swift`) builds with `cargo xtask swift build-framework --release`, which uses
`FFI_FEATURES = "sentry"` and the `small-release-stripped` profile at that commit (`xtask/src/swift.rs`).
The binary itself is built on Element's machines and isn't reproduced by Halo; building from source is Q-SDK-BUILD.

## Bump checklist
Follow docs/development/BUILD_AND_RELEASE.md §3: update all lines above from the new release commit, then run
`scripts/rust-license-inventory.py --sdk <checkout at sdk_commit> --write docs/security/inventory/rust-deps-matrix-sdk-ffi.csv`
and review the diff.
