# AGENTS.md — Engineering Contract for Halo

This file is binding for **every** contributor: AI coding agents and humans. If an instruction here conflicts with
a request, stop and ask the founder. If it conflicts with another document, this file wins for *process*, and
`docs/` wins for *behaviour*; report the conflict.

## 0. Mandatory procedure for every task
1. **Read this file completely** before changing anything.
2. **Read the relevant documents** before implementing: always [docs/architecture/MODULE_BOUNDARIES.md](docs/architecture/MODULE_BOUNDARIES.md);
   plus the feature spec in `docs/features/`, and for anything touching unread/receipts/notifications
   [docs/matrix/UNREAD_STATE.md](docs/matrix/UNREAD_STATE.md), [docs/matrix/READ_RECEIPTS.md](docs/matrix/READ_RECEIPTS.md), [docs/matrix/PUSH_NOTIFICATIONS.md](docs/matrix/PUSH_NOTIFICATIONS.md).
3. **Follow accepted decisions** ([docs/DECISION_LOG.md](docs/DECISION_LOG.md), [docs/adr/](docs/adr/README.md)). To change one, propose a new ADR — never silently deviate.
4. **Don't decide open questions silently.** If the task hits an item in [docs/OPEN_QUESTIONS.md](docs/OPEN_QUESTIONS.md), either perform the documented validation and record the result, or stop and ask.
5. **Run the relevant checks (§13) and report actual results** — the commands you ran and their real output. **Never claim tests passed without running them.** If you couldn't run something (e.g. iOS builds on Linux), say so explicitly.
6. **Update documentation in the same change** when behaviour, an interface or a decision changes.

## 1. Project overview
Halo is an independent, **proprietary** iOS Matrix client (SwiftUI, iOS 26+) built on the official `matrix-rust-sdk`
(consumed as the upstream UniFFI binary package). Priorities: **P0** read-state/notification correctness → **P1** core
messaging → **stickers v1** (in the MVP) → **P2** bot cards, Bot Activity, search, gallery. See [docs/README.md](docs/README.md).

## 2. Architecture in one picture
```
Feature* (SwiftUI views + @Observable VMs) ──► HaloApplication (coordinators/use cases) ──► HaloDomain (models, ports, pure policies)
                                                                                              ▲ implements ports
                     HaloMatrixAdapter (only importer of MatrixRustSDK) · HaloPersistence (GRDB) · HaloPlatform (iOS APIs)
Composition roots: Halo app target, HaloNotificationService (NSE) target
```

## 3. Technology stack
Swift 6 (strict concurrency), SwiftUI, Observation; upstream `MatrixRustSDK` (matrix-rust-components-swift, pinned exact version + checksum);
GRDB (exact version); Apple frameworks only otherwise. Infrastructure: Synapse (native sliding sync), MAS (from M5, D64), Sygnal with Halo's pushkin (`infra/sygnal/`, Python, server-side only, ADR-0015). Rust: none of our own unless gate G-FFI fails (then `core/halo-ffi` with UniFFI).

## 4. Non-negotiable principles
1. **Single source of truth.** Matrix state (events, receipts, room state, counts) lives on the server and in the SDK's replica. Halo stores only *derived, rebuildable* data and explicit *intents* (pending receipts) — never a second copy of Matrix sync state. **Never introduce a second source of truth for Matrix synchronization state.**
2. **One read-state function.** Attention, display counts and the app badge come only from `ReadStatePolicy` / `BadgeCalculator` in `HaloDomain`. No counters, no increments, no badge logic anywhere else (app or NSE).
3. **The boundary is sacred.** Only `HaloMatrixAdapter` imports `MatrixRustSDK`. No upstream type in any port, domain model, view model or public signature. **Never bypass the Rust/Swift architectural boundary.**
4. **Honest UI.** Unconfirmed things look unconfirmed (sending, pending bot actions, approximate counts).
5. **Interoperability.** Use spec events; Halo-specific data is optional and namespaced under the project namespace root `one.mbm.halo` (`one.mbm.halo.*`, D63).
6. **Privacy.** No content, tokens or raw Matrix IDs in logs; no third-party analytics/crash SDKs.
7. **Clean room.** No Element X code/assets/strings, nothing from the old fork, no AGPL/GPL code in prompts ([CONTRIBUTING.md](CONTRIBUTING.md)).
8. **Small surface.** No new dependency, abstraction layer or framework without a documented justification.
9. **Pushes are hints, not truth (D65).** A push only triggers work: the NSE fetches the event through the SDK, or the app reconciles from sync. The local unread engine, backed by Matrix sync state, is the sole authority for unread counts and the badge. **No push may set `aps.badge`** (ADR-0015).

## 5. Directory and module ownership
| Path | Contents | Rules |
|---|---|---|
| `docs/` | Requirements, architecture, ADRs | Keep consistent; run `scripts/validate-docs.sh` |
| `ios/Packages/HaloDomain/` | Models, ports, pure policies | Pure Swift; imports only HaloFoundation; must build on Linux |
| `ios/Packages/HaloApplication/` | Coordinators, use cases, routes | No SwiftUI/UIKit; Linux-buildable |
| `ios/Packages/HaloMatrixAdapter/` | Port implementations over MatrixRustSDK | Only place for upstream types; mapping tests required |
| `ios/Packages/HaloPersistence/` | GRDB DB, migrations, repositories | Append-only migrations; monotonic upserts |
| `ios/Packages/HaloPlatform/` | Notifications, BG tasks, Keychain, decoding | Apple APIs live here |
| `ios/Packages/HaloDesignSystem/`, `HaloBotRendering/` | UI tokens/components, bot cards | No business logic |
| `ios/Packages/Features/*` | Screens + view models | Depend on Application/Domain/DesignSystem only; never on another feature |
| `ios/App/`, `ios/NotificationService/` | Composition roots | Wiring only |
| `infra/`, `tools/`, `scripts/` | Servers, scenario driver, scripts | No secrets (`.env.example` only) |
Full dependency table: [docs/architecture/MODULE_BOUNDARIES.md](docs/architecture/MODULE_BOUNDARIES.md).

## 6. Swift conventions
Per [docs/development/CODE_CONVENTIONS.md](docs/development/CODE_CONVENTIONS.md). Highlights: value types for models; `@MainActor @Observable final class` view models;
no logic in views; `HaloError` everywhere across ports; no `try!`, no force unwraps outside tests; `HaloLog` with privacy annotations; no Combine in new code.

## 7. Rust conventions (only if `core/` exists)
Edition 2024, rustfmt, `clippy -D warnings`, `forbid(unsafe_code)` in Halo crates, `thiserror`, no `unwrap` in non-test code, UniFFI 0.32.x matching the SDK, port-shaped coarse APIs.

## 8. FFI conventions
- Map upstream → domain immediately in listener callbacks; never block the callback thread; never call back into the FFI synchronously from a callback.
- Every upstream `TaskHandle` is owned by a `SubscriptionToken` and cancelled on teardown.
- All upstream errors go through `ErrorMapper` → `HaloError`.
- SDK bumps: compile fixes only inside the adapter; follow [docs/development/BUILD_AND_RELEASE.md](docs/development/BUILD_AND_RELEASE.md) §3.

## 9. Concurrency rules
Swift 6 strict mode, zero warnings. Coordinators/adapters are actors; UI is `@MainActor`. Long-lived tasks are owned and cancelled. Forbidden:
`DispatchQueue.main.sync`, semaphores waiting on async work, unjustified `Task.detached`, shared mutable singletons, `@unchecked Sendable` without a written justification.
Cross-process writes (app/NSE) must be monotonic upserts. Details: [docs/architecture/CONCURRENCY.md](docs/architecture/CONCURRENCY.md).

## 10. Error handling
Typed `HaloError` at every port; map once in the adapter; log once where handled; no silent `try?` on state-changing operations;
retry only retryable errors with backoff. Details: [docs/architecture/ERROR_HANDLING.md](docs/architecture/ERROR_HANDLING.md).

## 11. Dependency rules
Before adding or upgrading **any** dependency: (1) justify it in the PR/commit; (2) verify its licence file (not just package metadata) and add a row to
[docs/security/DEPENDENCY_INVENTORY.md](docs/security/DEPENDENCY_INVENTORY.md); (3) allowed licences per [docs/security/LICENSE_COMPLIANCE.md](docs/security/LICENSE_COMPLIANCE.md) §4 — GPL/LGPL/AGPL/SSPL/BUSL are forbidden;
(4) pin the exact version; (5) for the SDK, follow the bump procedure and regenerate the Rust inventory.

## 12. Testing requirements
- Every behaviour change ships with tests at the lowest sensible layer ([docs/testing/TEST_STRATEGY.md](docs/testing/TEST_STRATEGY.md)).
- **Every bug fix adds a regression test** that fails before the fix. Read-state bugs add a trace fixture ([docs/testing/UNREAD_REGRESSION_TESTS.md](docs/testing/UNREAD_REGRESSION_TESTS.md) §4).
- Changes to `ReadStatePolicy`, receipts, NSE or the outbox must keep P1–P10 and S01–S22 green.
- Port changes start with a failing contract test and update the fake.
- No sleeps in tests; inject clocks and schedulers.

## 13. Build and validation commands
| Purpose | Command | Available from |
|---|---|---|
| Documentation checks | `scripts/validate-docs.sh` | **Phase 0** |
| Module boundary checks | `scripts/check-boundaries.sh` | M0 |
| Pure package tests (Linux or macOS) | `swift test --package-path ios/Packages/<Package>` | M0 |
| App build | `xcodebuild -project ios/Halo.xcodeproj -scheme Halo-Debug -destination 'platform=iOS Simulator,name=<device>' build` | M0 (macOS only) |
| Adapter/FFI tests | `xcodebuild … -scheme HaloMatrixAdapterTests test` against `infra/dev` | M1 |
| Scenario suite | `docker compose -f infra/test/docker-compose.yml up -d && swift run --package-path tools/scenario-driver scenario-driver all` | M3 |
| Secret scan | `gitleaks detect` | M0 |
Commands that don't exist yet must not be reported as run.

## 14. Security requirements
Keychain for secrets (`afterFirstUnlockThisDeviceOnly`, non-synchronizable); file protection `completeUntilFirstUserAuthentication`; never log sensitive data
([docs/security/SECURITY.md](docs/security/SECURITY.md) §6); never disable TLS verification; never commit secrets; direct HTTP calls only where documented.

## 15. Documentation requirements
Use the statement labels ([VERIFIED]/[DECISION]/[ASSUMPTION]/[OPEN]); cite [docs/SOURCES.md](docs/SOURCES.md) for verified facts; never invent API names, versions or capabilities —
verify in the pinned SDK source or mark as [ASSUMPTION] with a V-item. One fact, one place. Mermaid for diagrams.

## 16. Git and commit conventions
Conventional Commits with a module scope (`feat(read-state): …`); body explains why and cites Dnn/R-ids; one logical change per commit; docs in the same commit;
never commit secrets or binaries; never rewrite shared history.

## 17. Forbidden implementation patterns
- Importing `MatrixRustSDK` outside `HaloMatrixAdapter`; upstream types in public/port signatures.
- Storing Matrix events, receipts, room state or counts in `halo.sqlite` as truth; badge increments; computing attention outside `ReadStatePolicy`.
- Using any push payload field (`counts.unread`, `unread_count`, `aps.badge`) as a count, a read position or the badge; letting any push reach the device with `aps.badge`; creating attention from a payload without fetching the event through the SDK.
- Sending receipts from the NSE; starting `SyncService` in the NSE.
- Hidden bot commands or new bot APIs; reacting to a todo-list message (D23); treating reaction delivery as completion.
- Feature → feature imports; business logic in SwiftUI views.
- Placeholder implementations that pretend to work (e.g. returning fake data from a real adapter).
- `print`, `try!`, force unwraps in production code; disabling TLS checks; analytics SDKs.
- Copying code from Element X or any copyleft source.
