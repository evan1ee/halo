# Rust ⇄ Swift FFI Strategy

Decisions: D44, ADR-0002, ADR-0003.

## 1. Options compared

| Option | Description | Pros | Cons | Verdict |
|---|---|---|---|---|
| **A. Upstream UniFFI bindings (binary)** | Use `matrix-sdk-ffi` as shipped (prebuilt or built from a pinned rev) | No Rust code to own; the same bindings Element ships; Apache-2.0 | API shaped by Element's needs, unstable; upstream objects can't be extended (F-FFI-3); some data (event-cache gaps, custom required state) not exposed | **MVP choice** |
| **B. Halo-owned UniFFI crate** | `core/halo-ffi` depends on `matrix-sdk`/`matrix-sdk-ui`; exports a Halo-designed API | Full access to SDK internals; a stable API we control; async support, callbacks, generated Swift | Months of binding work; the Rust build pipeline becomes ours | **Fallback if G-FFI fails** |
| C. Hand-written C ABI (`extern "C"` + cbindgen + Swift wrapper) | Manual FFI | Total control of memory layout and threading | Manual memory management, error marshalling, async bridging, callback lifetimes; error-prone; no gain for this project | Rejected |
| D. swift-bridge / other generators | Alternative generators | Some ergonomic benefits | Smaller community; matrix-sdk already uses UniFFI; mixing generators in one binary is risky | Rejected |
| E. Native Swift Matrix SDK | No Rust | Single language | Re-implementing E2EE/sync; deprecated `matrix-ios-sdk` has no sliding sync | Rejected |

## 2. Why UniFFI for any Halo-owned FFI (ADR-0003)
- UniFFI generates Swift for Rust `async fn` (bridged to Swift `async`), objects (`Arc<T>` → Swift class with
  reference counting), records/enums (value types), errors (Swift `Error`) and callback interfaces — which is everything this project needs.
- The upstream SDK uses it **[VERIFIED F-FFI-2]** (UniFFI 0.32.x), so a Halo crate would share the toolchain and
  could reuse upstream patterns (e.g. `TaskHandle` for cancellation).

## 3. Memory ownership rules (apply to upstream bindings today and to `halo-ffi` later)
- Rust objects exposed as `Arc<T>` become Swift classes; Swift holds a strong reference; Rust frees them when the last Swift reference is released.
- **Never** keep an upstream object outside `HaloMatrixAdapter`. Map to Swift value types at the boundary.
- Callback interfaces (listeners) are retained by Rust until the returned `TaskHandle` is cancelled or dropped → always keep the handle and cancel it explicitly.
- Large payloads (media) go through files (`get_media_file` → temporary file handle) or `Data`, never strings.

## 4. Threads and async
See [../architecture/CONCURRENCY.md](../architecture/CONCURRENCY.md) §3. In short: Rust owns the tokio runtime;
Swift `await`s FFI `async` methods from adapter actors; callbacks arrive on Rust threads and are forwarded into
`AsyncStream`s without blocking.

## 5. Cancellation
- Swift task cancellation does **not** automatically cancel an in-flight Rust future across UniFFI
  **[ASSUMPTION V-FFI-1: verify UniFFI 0.32 cancellation semantics for async calls]**. The adapter therefore
  treats FFI calls as non-cancellable units and checks `Task.isCancelled` before and after.
- Subscriptions are cancelled with `TaskHandle.cancel()`.

## 6. Error propagation
Rust `Result<T, E>` → Swift `throws` (typed upstream errors). Panics: the distributed Apple profile
`small-release-stripped` inherits `release` and sets no `panic = "abort"` **[VERIFIED F-FFI-17]**, so unwinding is on and
UniFFI can catch panics at the boundary **[ASSUMPTION V-FFI-2: UniFFI 0.32 maps caught panics to an error for the
caller (unexpected-error path) — confirm in the UniFFI manual]**. Treat any such error as `HaloError.internal` and log it.

## 7. The future Halo-owned layer (if G-FFI fails)
- `core/` Rust workspace: `halo-ffi` (UniFFI, `crate-type = ["staticlib", "lib"]`), depending on `matrix-sdk`, `matrix-sdk-ui` (pinned git rev, unmodified).
- It exports **only what the ports need**, shaped like the ports, so the Swift adapter becomes thin.
- Built into `HaloCore.xcframework` with `uniffi-bindgen generate --library` (same approach as upstream F-FFI-2).
- Both XCFrameworks must never be linked into the same binary (duplicate SDK copies): the switch is all-or-nothing per release.
