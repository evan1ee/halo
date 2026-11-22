# Module Boundaries

**[DECISION ADR-0008, ADR-0022]** Code lives in two local Swift packages under `ios/Packages/`:
`HaloCore` (Linux-buildable: `HaloFoundation`, `HaloDomain`, `HaloApplication`, `HaloTestSupport`) and
`HaloApple` (iOS/Apple targets: `HaloMatrixAdapter`, `HaloPersistence`, `HaloPlatform`, `HaloDesignSystem`,
`HaloBotRendering`, and every `Feature<Area>` target). The Xcode project contains only the two composition
roots (`Halo`, `HaloNotificationService`). Boundaries are enforced by target dependencies in the two
manifests and by `scripts/check-boundaries.sh` (see [../development/CI_CD.md](../development/CI_CD.md)).

## 1. Modules

| Module | Layer | Responsibility | May depend on | Builds on Linux |
|---|---|---|---|---|
| `HaloFoundation` | base (cross-cutting) | `HaloError`, Matrix identifiers (`UserID`, `RoomID`, `EventID`, `DeviceID`), seeded RNG for deterministic jitter and property tests; later the logging facade, redaction and clocks | — | ✅ |
| `HaloDomain` | 3 | Value models, **ports** (protocols), pure policies: `ReadStatePolicy`, `BadgeCalculator`, `ImagePackParser`, `BotTemplateParser` registry | HaloFoundation | ✅ |
| `HaloApplication` | 2 | Use cases and coordinators (session, sync, read state, outbox, notifications, stickers, bot index) | HaloDomain, HaloFoundation | ✅ (no UIKit/UserNotifications) |
| `HaloMatrixAdapter` | 4 | Implements Matrix ports using `MatrixRustSDK`; maps upstream types ⇄ domain values | HaloDomain, HaloFoundation, **MatrixRustSDK** | ❌ |
| `HaloPersistence` | 5 | GRDB database, migrations, repositories implementing persistence ports | HaloDomain, HaloFoundation, GRDB | ✅ (tests use in-memory DB) |
| `HaloPlatform` | 6 | UserNotifications, BackgroundTasks, Keychain, file protection, ImageIO decoding, haptics | HaloDomain, HaloFoundation | ❌ |
| `HaloDesignSystem` | 1 | Tokens, components, HTML-subset → `AttributedString` renderer | HaloFoundation | ❌ |
| `HaloBotRendering` | 1 | `BotMessageRenderer`: cards for parsed templates, generic fallback | HaloDomain, HaloDesignSystem | ❌ |
| `Feature*` (Onboarding, RoomList, Timeline, Composer, Media, RoomDetails, Profile, Search, Settings, Stickers, BotActivity) | 1–2 | Screens + `@Observable` view models | HaloApplication, HaloDomain, HaloDesignSystem, HaloBotRendering (Timeline, BotActivity only), HaloFoundation | ❌ |
| `HaloTestSupport` | test | Fakes of every port, the shared port contract suites, fixture loaders, scenario builders | HaloDomain, HaloFoundation (not HaloApplication: its tests use these fakes, and SwiftPM forbids package cycles) | ✅ |
| `Halo` (app target) | root | `AppContainer`, scene setup, deep links | all | ❌ |
| `HaloNotificationService` (NSE target) | root | NSE entry point; the notification pipeline | HaloApplication, HaloDomain, HaloMatrixAdapter, HaloPersistence, HaloPlatform, HaloFoundation | ❌ |
| `HaloShareExtension` (share extension target) | root | Stages shared items into the App Group inbox; no session, no network (D87) | HaloPlatform, HaloDomain, HaloFoundation | ❌ |

```mermaid
flowchart BT
  F[HaloFoundation]
  D[HaloDomain] --> F
  AP[HaloApplication] --> D
  MX[HaloMatrixAdapter] --> D
  MX --> SDK[(MatrixRustSDK)]
  PE[HaloPersistence] --> D
  PE --> GRDB[(GRDB)]
  PL[HaloPlatform] --> D
  DS[HaloDesignSystem] --> F
  BR[HaloBotRendering] --> D
  BR --> DS
  FE[Feature*] --> AP
  FE --> DS
  FE --> BR
  APP[Halo app] --> FE & MX & PE & PL
  NSE[NSE target] --> AP & MX & PE & PL
```

### Module naming
| Kind | Pattern | Examples |
|---|---|---|
| Layer or shared library | `Halo<Layer>` | `HaloDomain`, `HaloMatrixAdapter`, `HaloDesignSystem`, `HaloTestSupport` |
| Feature (screens + view models) | `Feature<Area>` | `FeatureTimeline`, `FeatureRoomList`, `FeatureStickers` |
| Composition roots | `Halo` (app), `HaloNotificationService` (NSE); later extensions `Halo<Extension>` | — |
| Test targets | `<Module>Tests` | `FeatureTimelineTests` |

Why: (1) `scripts/check_boundaries.py` identifies feature modules by the `Feature` prefix to enforce the rules in §2, so a
feature without it escapes the checks; (2) a module must never share a name with a type: Swift then can't qualify the
module (`Timeline.Item` becomes ambiguous), and bare area names like `Timeline`, `RoomList` or `Settings` are already types in
the SDK or `HaloDomain`; (3) the prefix shows the layer in import lists and sorts features together. `<Area>` is
UpperCamelCase, singular for a thing (`FeatureProfile`) and the screen's name for a flow (`FeatureOnboarding`), and reuses the
area names of the core layers ([../adr/0022-module-layout-v2.md](../adr/0022-module-layout-v2.md) folder rule, D86).
Renaming an existing module needs a reason beyond style.

## 2. Forbidden dependencies

| Rule | Reason |
|---|---|
| ❌ Anything except `HaloMatrixAdapter` imports `MatrixRustSDK` | Keeps the FFI replaceable (D44) |
| ❌ `HaloDomain` imports any Halo module other than `HaloFoundation`, or SwiftUI, UIKit, GRDB, UserNotifications | Pure, portable, testable on Linux |
| ❌ `HaloFoundation` imports any other Halo module | It is the base every module may use |
| ❌ `Feature*` imports `HaloMatrixAdapter`, `HaloPersistence`, `HaloPlatform` | Features talk to use cases, not infrastructure |
| ❌ `Feature*` imports another `Feature*` | Independent development; navigation goes through routes in `HaloApplication` |
| ❌ `HaloApplication` imports SwiftUI/UIKit | Keeps use cases UI-independent |
| ❌ Upstream FFI types in a port signature or a domain model | Same as the first rule |
| ❌ `HaloPersistence` stores Matrix events, receipts or room state as truth | Single source of truth (DATA_FLOW §1) |
| ❌ Badge or attention computed outside `BadgeCalculator` / `ReadStatePolicy` | D9 |

## 3. The Rust/Swift boundary

```mermaid
flowchart LR
  subgraph Swift
    Ports["HaloDomain ports<br/>(Halo-owned, versioned)"]
    Adapter["HaloMatrixAdapter"]
  end
  subgraph Binary["MatrixRustSDK (binary, upstream)"]
    FFI["UniFFI-generated Swift"]
    Rust["matrix-sdk-ffi → matrix-sdk-ui → matrix-sdk"]
  end
  Ports <-. implemented by .- Adapter
  Adapter --> FFI --> Rust
  subgraph Future["If G-FFI fails"]
    HaloFFI["core/halo-ffi (Halo-owned UniFFI)"]
  end
  Adapter -. swap .-> HaloFFI
```

The **ports** are the stable contract ([../matrix/PORTS_CONTRACT.md](../matrix/PORTS_CONTRACT.md)). The FFI
under the adapter can change (SDK bumps, or a switch to Halo-owned bindings) without touching anything above the adapter.

## 4. Module ownership

Solo phase: the founder owns everything. For future collaboration, ownership is recorded in
`.github/CODEOWNERS` (planned for M0) by path: `ios/Packages/HaloMatrixAdapter/` and `HaloDomain/ReadState/` need
review from the "core" owner; feature packages need review from the "app" owner.
