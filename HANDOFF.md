# Halo — Session Handoff

Last updated: 2026-11-19 · Branch: `claude/m0b-adapter-scaffold` · PRs #1, #2 merged; this branch not yet pushed

Updated in the last commit of every push (AGENTS.md §18). Summarises and links; the facts live in `docs/`.

## 1. Current status
- **Milestone:** M0 Foundation, split because no Mac is available yet (docs/ROADMAP.md → "M0 without a Mac").
  **M0a done. M0b started** on a Mac (Xcode 27.2, Swift 6.4.2).
- **Phase 0 documentation:** approved by the founder (2026-11-19).
- **CI:** workflows `docs`, `swift-linux`, `boundaries`, `secrets`, `handoff` run on PR #1 (first run there; results not yet
  reviewed in a session). `licenses` runs only when SDK/inventory files change.
- **Local checks at this push:** `scripts/prepush.sh` — handoff, docs, boundaries, 4 Swift packages (Swift 6.2.4 Linux), gitleaks
  pass; SwiftLint skipped (not configured). Nothing iOS-specific has been built anywhere.

## 2. Completed work
**2026-11-19 (later) — M0b: adapter implemented, contract run pending**
- `HaloMatrixAdapter`: `ErrorMapper`, `MatrixBootstrap`, `MatrixSessionPort` (actor; discovery, password login, restore, logout, token-refresh
  events; payload JSON holds SDK session + per-login store dir + random store passphrase, Keychain-only), `MatrixRoomListPort`
  (dynamic adapters, ordered mapping, `.unread` filter → `.unsupported` until M1). SDK API names verified in the pinned package source.
- OrbStack installed; `infra/dev` up, `smoke.sh` passes. **9 adapter tests pass against it** (`SessionPortContract` and
  `RoomListPortContract` with 2 rooms), run with `TEST_RUNNER_HALO_DEV_SERVER/USER/PASSWORD/ROOMS` set for `xcodebuild … test`.
  Bug found by the contract and fixed with a regression test: Synapse answers a wrong password with `M_FORBIDDEN`, now mapped to
  `unauthorized(soft: false)` for the login call only (`ErrorMapper.mapLogin`).
- V-CI-2 resolved (CI 6.2.4 floor vs Xcode Swift 6.4.2; all packages pass on both).
- `HaloMatrixAdapter` package added; pinned SDK 26.11.17 resolves, links and builds for the iOS Simulator; 1 smoke test passes via
  `xcodebuild -scheme HaloMatrixAdapter -destination 'platform=iOS Simulator,name=iPhone 17' test`. The xcframework has no macOS
  slice, so `swift build` fails for this package by design; use xcodebuild.
- `scripts/prepush.sh` passes (gitleaks, swiftlint not installed → skipped).

**2026-11-19 — documentation review, founder decisions, M0a, handoff rule**
- Phase 0 review: read-position vs notification-coverage split in the unread engine (UNREAD_STATE §5), Synapse count-only pushes
  (ADR-0015), separate NSE gate (ADR-0016), contradictions and citations fixed, validator extended.
- `infra/dev`: Synapse v1.165.0 + Postgres, native password login, native sliding sync; `smoke.sh` passes.
- `ios/Packages`: HaloFoundation, HaloDomain (SessionPort, RoomListPort, KeychainPort, RoomListReducer), HaloTestSupport (fakes +
  port contract suites), HaloApplication (SessionCoordinator, RoomListCoordinator). Tests: 10 + 4 + 3 + 21 pass.
- Tooling: `check-boundaries.sh`, `rust-license-inventory.py` (licence gate), `prepush.sh`, gitleaks 8.30.1, CI workflows.
- Validation resolved: V-CI-1 (GRDB on Linux), V-SDK-1 (prebuilt 26.11.17 ← SDK `b93751e`), V-PUSH-2 (false), V-TL-1.
- Session Handoff Rule (this push): `HANDOFF.md`, AGENTS.md §18, pre-push hook, `handoff.yml`, validator check.

## 3. Key decisions
Full list: docs/DECISION_LOG.md (D1–D67), docs/adr/ (ADR-0001…0016, all accepted).
- **D63** namespace root `one.mbm.halo` for every identifier (table: docs/development/DEVELOPMENT_SETUP.md §3).
- **D64** M0 uses Synapse's native password login; MAS from M5.
- **D65 / ADR-0015** pushes are hints, never truth; no push may set `aps.badge`; Halo's Sygnal pushkin converts count-only pushes
  into background pushes (relay only as fallback).
- **D66 / ADR-0016** gate G-NSE at the end of M1 with AC-NSE-1…6 (docs/features/NOTIFICATIONS.md §11).
- **D67** this Session Handoff Rule.
- **D47** read state: `readPosTs` (true read position) is separate from `notifiedThroughTs` (notification coverage).

## 4. Modified files (this push)
- New: `ios/Packages/HaloMatrixAdapter/` (Package.swift, ErrorMapper, Bootstrap, MatrixSessionPort, MatrixRoomListPort, unit + gated contract tests).
- Docs: `docs/OPEN_QUESTIONS.md` (V-CI-2), `docs/development/DEVELOPMENT_SETUP.md` §2, `docs/ROADMAP.md`, `HANDOFF.md`.

## 5. Outstanding issues
- Contract tests are env-gated and are reported as skipped (not passed) without a homeserver; `prepush.sh` doesn't build/test the adapter.
- Docker CLI on this Mac hangs on the `osxkeychain` credential helper (image pulls fail with "error getting credentials"). Workaround used: a throwaway `DOCKER_CONFIG` plus a stub `docker-credential-osxkeychain` first in PATH; the user's config was not touched. Native Synapse via pip doesn't load on macOS 27. `prepush.sh` doesn't build/test the adapter (needs xcodebuild).
- `RefreshDelegate.saveSessionInKeychain` uses `try?` when encoding a refreshed session (no logger yet); add `HaloLog` + a test when HaloPlatform lands.
- Sync service is started on first room-list use and stopped only at logout (no lifecycle owner yet).
- PR #1 CI results haven't been checked yet — first task of the next session.
- M0 exit criterion (password login against `infra/dev` shows the room count via ports) needs the Mac (M0b).
- Not yet run anywhere: Xcode/simulator builds, the adapter contract tests, SwiftLint (no `.swiftlint.yml` yet).
- Open validation items for M0b: V-CI-2 (Xcode Swift version = CI 6.2?), V-SQL-1, V-APPLE-1. For M1: V-NSE-*, V-PUSH-1/3/5, V-RS-1/5.
- Synapse advertises spec versions only up to v1.17 (SOURCES F-SYN-2); relevant to sticker interop (risk COMPAT-2), not to M0.
- Docker Hub rate-limited pulls in the last session (Sygnal image not pulled; Swift 6.3 tag unchecked).

## 6. Next steps
1. Push this branch / open a PR; check CI.
2. (Done) contracts pass on infra/dev. Keep running them after every adapter change.
3. M0b continued — Xcode project (`one.mbm.halo`, `HALO_NAMESPACE` in `ios/Config/Base.xcconfig`) →
   HaloPlatform Keychain + log sink → adapter public-API rule in `check-boundaries` → V-SQL-1, V-APPLE-1 → exit criterion.
4. Without a Mac: V-APPLE-1 from Apple docs; M1 prep — Halo's Sygnal pushkin in `infra/sygnal/` with tests and `pushkin.yml` (ADR-0015).

## 7. Next Session Prompt
```text
Continue development of Halo (repository evan1ee/halo).

1. Read AGENTS.md completely, then HANDOFF.md (sections 1–6). Run scripts/install-hooks.sh once.
   Trust HANDOFF.md for the project state; read other docs only as the task needs them.
2. Branch claude/m0b-adapter-scaffold: push/open PR if not done; check CI. Adapter code exists; run its contract tests against infra/dev first.
3. Then do HANDOFF.md section 6 "Next steps":
   - On a Mac with Xcode for the iOS 26 SDK: finish M0 (M0b) in the order listed there. Key references:
     docs/matrix/PORTS_CONTRACT.md, docs/matrix/SDK_INTEGRATION.md, docs/development/DEVELOPMENT_SETUP.md §3,
     ios/SDKVERSION.md (verify every SDK API at commit b93751e; never invent names).
   - Without a Mac: V-APPLE-1, then Halo's Sygnal pushkin (ADR-0015). Don't start the Xcode project or
     the adapter, and don't write code you can't compile and test.
4. Follow AGENTS.md exactly: run the checks (scripts/prepush.sh) and report real output; say what you
   couldn't run; tests for every behaviour change; Conventional Commits; docs in the same commit;
   don't decide open questions silently.
5. Before every git push (AGENTS.md §18): update HANDOFF.md (all 7 sections, this prompt included),
   bring ROADMAP/OPEN_QUESTIONS/specs up to date, and include HANDOFF.md in the last commit of the push.
```
