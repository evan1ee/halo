# Code Conventions

## 1. Swift
- **Language:** Swift 6 mode, strict concurrency, no warnings.
- **Naming:** Swift API Design Guidelines. Types `UpperCamelCase`; files named after their main type; one primary type per file.
- **Modules:** public API minimal; default `internal`; `package` access for cross-target helpers within a package.
- **Value types first:** domain models are `struct`/`enum`, `Sendable`, `Equatable`; classes only for identity/lifecycle (view models, adapters).
- **View models:** `@MainActor @Observable final class XViewModel`; inputs via `init` (dependencies) and intent methods (`func didTapSend()`); no SwiftUI types in view models except `@Observable`.
- **Views:** small, composable; no business logic; previews use fakes from `HaloTestSupport`.
- **Errors:** throw `HaloError`; no `fatalError` outside unreachable code with a message; no force unwraps except in tests and on compile-time constants.
- **Async:** `async/await`; `AsyncStream` for events; no Combine in new code (allowed only to bridge an Apple API).
- **Logging:** `HaloLog` only, with privacy annotations ([../security/SECURITY.md](../security/SECURITY.md) §6).
- **Formatting:** swift-format default style **[DECISION D62]**, 120 columns; SwiftLint for rules not covered (custom rules: no `print`, no `import MatrixRustSDK` outside the adapter, no `try!`).
- **Documentation comments** on every public port, policy and coordinator method, including threading and error behaviour.

## 2. Rust (only for building the SDK from source or `core/halo-ffi` after G-FFI)
- Edition 2024, `rustfmt` default, `clippy -D warnings`, `#![forbid(unsafe_code)]` in Halo crates (except generated scaffolding).
- Errors with `thiserror`; no `unwrap()`/`expect()` in non-test code without a `// SAFETY:`-style justification.
- Async with the SDK's tokio runtime; no `block_on` inside async code.

## 3. FFI conventions (adapter)
- One adapter type per port (`MatrixSessionAdapter: SessionPort` …).
- Upstream → domain mapping in `Mapping/` files with unit tests per type.
- Listener classes are `final class … : <UpstreamListener>, @unchecked Sendable` **only** with an `AsyncStream.Continuation` as their stored state (justified in a comment).
- Every `TaskHandle` is owned by a `SubscriptionToken`.
- No upstream type escapes a `public`/`package` declaration (checked by `check-boundaries.sh`, which greps the adapter's public interface).

## 4. Tests
- Names: `test_<unit>_<condition>_<expected>()` or Swift Testing `@Test("<behaviour>")`.
- Arrange–Act–Assert; one behaviour per test; fakes over mocks; no sleeps (use injected clocks).
- Fixtures under `Tests/<Target>/Fixtures/`, with a `SOURCE.md` naming their origin and licence.

## 5. Git
- Branches: `main` (always green); work branches `feat/…`, `fix/…`, `docs/…`, `chore/…`.
- Commits: Conventional Commits with a scope = module (`feat(read-state): …`, `fix(adapter): …`, `docs(adr): …`). Body explains *why*. Reference decision/requirement IDs.
- One logical change per commit; docs updated in the same commit as behaviour changes.
- No secrets, no generated binaries (XCFrameworks are fetched by SwiftPM, never committed).

## 6. Documentation
- Follow the labels in [../README.md](../README.md). New decisions → DECISION_LOG (+ ADR when architectural).
- Mermaid for diagrams. No duplicated facts — link instead.
