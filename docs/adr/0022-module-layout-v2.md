# ADR-0022: Module and folder layout v2

- **Status:** Accepted (founder, 2026-11-22) — refines ADR-0008, does not replace its layering
- **Date:** 2026-11-22
- **Decision IDs:** D86
- **Validation:** none — mechanical moves, checked by `scripts/check-boundaries.sh`, `scripts/prepush.sh` and the app build

## Context
ADR-0008 set up one local SwiftPM package per layer and per feature. The layering works: the compiler and
`check-boundaries.sh` keep `MatrixRustSDK` inside the adapter and features apart, and the pure packages run on Linux CI.
After M0–M10 the *contents* have drifted from the plan in [../architecture/MODULE_BOUNDARIES.md](../architecture/MODULE_BOUNDARIES.md),
and the M11–M15 work ([../ROADMAP.md](../ROADMAP.md)) adds screens that have no obvious home. Evidence at commit `8da66aa`:

| # | Drift | Evidence |
|---|---|---|
| 1 | Features hold things that aren't theirs: message search, the global media gallery and new chat live in `FeatureRoomList`; user profiles in `FeatureRoomDetails`; app-wide `AppPreferences` and the diagnostics `.zip` writer in `FeatureSettings`; device recovery in `FeatureAuth` | `ios/Packages/Features/*/Sources` |
| 2 | P0 read-state logic in a UI package: `TimelineReadTracker` (pure, ADR-0020) lives in `FeatureTimeline`, so it isn't built or tested by Linux CI next to `ReadStatePolicy` | `FeatureTimeline/TimelineReadTracker.swift` |
| 3 | Planned modules missing: `HaloBotRendering`, `FeatureComposer` and `FeatureProfile` are in MODULE_BOUNDARIES §1 and AGENTS.md §5 but don't exist; bot cards and HTML rendering sit inside `TimelineView.swift` | MODULE_BOUNDARIES §1 |
| 4 | Two copies of the paged photo viewer (`TimelinePhotoViewer` and the gallery detail, both `TabView(selection:)`) | `TimelineView.swift:1154`, `GlobalMediaGalleryView.swift:342` |
| 5 | Routes live in the app (`private enum HomeRoute` in `HaloApp.swift`) although NAVIGATION §2 puts them in `HaloApplication/Navigation`; `ios/App/` is two flat files holding all composition (1,081 lines) | `App/HaloApp.swift:30` |
| 6 | Flat adapter and test-support folders (22 and 24 files) while `HaloDomain` and `HaloApplication` group by area | package trees |
| 7 | Build cost: 15 `Package.swift` files with the same boilerplate, each with its own `.build` (5.2 GB in total on the dev Mac, 997 MB for the adapter alone) | `du -sh ios/Packages` |
| 8 | Paths in AGENTS.md and docs that don't exist: `infra/test/`, `infra/sygnal/` (the template is in `infra/dev/sygnal/`), `swift run --package-path tools/scenario-driver` (the driver is `run_scenarios.py`) | `ls infra tools` |

## Problem
How should modules and folders be arranged so that every file has one obvious home, the P0 logic stays Linux-tested, the
M11–M15 screens fit without more drift, and the build stays cheap — without weakening the boundaries?

## Considered alternatives
1. **Keep the layout, fix only the misplaced files.** Cheapest; leaves the 15 manifests, the per-package build cost and the
   flat folders.
2. **Two manifests, many targets (recommended).** `ios/Packages/HaloCore` (Linux: Foundation, Domain, Application, TestSupport)
   and `ios/Packages/HaloApple` (Adapter, Persistence, Platform, DesignSystem, BotRendering and every feature as its own target).
   Boundaries stay compiler-enforced through *target* dependencies; one `.build` per side; a new feature is five lines.
3. **One manifest for everything.** Simplest to read, but Linux CI would have to resolve the iOS-only SDK binary and skip
   Apple targets by hand.
4. **One app target with folders.** Rejected by ADR-0008: no compiler-enforced boundaries.

## Decision
Option 2, done in the steps below. Each step is a separate commit that keeps `prepush.sh` green.

```text
ios/
  App/
    HaloApp.swift                  # @main, scene, lifecycle only
    Composition/                   # AppRoot split by area: SessionAssembly, ChatsAssembly,
                                   #   SettingsAssembly, NotificationsAssembly, BotsAssembly
    Resources/                     # Assets.xcassets, Localizable.xcstrings, PrivacyInfo.xcprivacy (M11, M14, M15)
    Support/                       # Info*.plist, Halo.entitlements
  NotificationService/             # + Resources/PrivacyInfo.xcprivacy
  Packages/
    HaloCore/                      # Linux-buildable; Linux CI runs `swift test` here
      Sources/{HaloFoundation, HaloDomain, HaloApplication, HaloTestSupport}/
      Tests/…
    HaloApple/                     # iOS (and macOS for the pure-Swift feature tests)
      Sources/
        HaloMatrixAdapter/{Session, Sync, RoomList, Rooms, Timeline, Media, Stickers,
                           Encryption, Notifications, Account, Support}/
        HaloPersistence/  HaloPlatform/  HaloDesignSystem/{Tokens, Components, Media}/
        HaloBotRendering/          # BotCardView, HTMLText (D29) out of FeatureTimeline
        FeatureOnboarding/         # was FeatureAuth: welcome, sign-in, verify device, priming (S1, S2, S14, S15)
        FeatureRoomList/           # room list + new chat
        FeatureTimeline/           # timeline only (TD-11 split)
        FeatureComposer/           # composer, attachments, mentions (MODULE_BOUNDARIES plan)
        FeatureRoomDetails/        # room details, members, room gallery, export
        FeatureProfile/            # user profile + own profile settings
        FeatureMedia/              # global gallery + the one shared photo viewer + Quick Look
        FeatureSearch/             # message search results (D85 searchable list)
        FeatureStickers/  FeatureBotActivity/  FeatureSettings/
      Tests/…
```

Moves of logic to the layer that owns it:
- `TimelineReadTracker` → `HaloDomain/ReadState/` (with its tests), so Linux CI covers it.
- `AppPreferences` → a `PreferencesPort` in `HaloDomain` with a `UserDefaults` store in `HaloPlatform` (TD-02).
- `DiagnosticsZipArchive` → `HaloPlatform`; route enums → `HaloApplication/Navigation/` (NAVIGATION §2).
- Folder rule: `HaloDomain`, `HaloApplication`, `HaloMatrixAdapter` and `HaloTestSupport` use the **same area names**
  (`Session`, `Sync`, `RoomList`, `Timeline`, `Media`, `Stickers`, `Encryption`, `Notifications`, `Bots`, `Search`, `Account`),
  so a port, its coordinator, its adapter and its fake are found by the same path. Features stay flat until they pass about
  eight files, then split into `Views/` and `ViewModels/`.
- Naming rule: unchanged — `Halo<Layer>` for layers, `Feature<Area>` for features, never a module named after a type
  ([../architecture/MODULE_BOUNDARIES.md](../architecture/MODULE_BOUNDARIES.md) §1 "Module naming"). The new modules above follow
  it; in the two-manifest layout they become target names, and `check_boundaries.py` keeps matching the `Feature` prefix on
  targets instead of packages. Suffix (`TimelineFeature`) and bare names were considered and rejected: no functional gain for
  the churn, and bare names clash with SDK/domain types.

Order (riding on the tech-debt phases of [../development/TECH_DEBT.md](../development/TECH_DEBT.md)):
1. With M11: doc path fixes (drift 8); `TimelineReadTracker` to the domain; `HaloDesignSystem/{Tokens, Components}`; `App/Resources`.
2. With M12: routes to `HaloApplication`; `App/Composition` split; `FeatureSearch`; `FeatureProfile`.
3. Before M13: `HaloBotRendering`, `FeatureComposer`, `FeatureMedia` (one viewer) as part of the TD-11 split; `FeatureOnboarding` rename.
4. After M13 merges (quiet point, nothing in flight): the two-manifest consolidation and the adapter/test-support area folders,
   as one mechanical pull request with no behaviour change.

## Rationale
- Fix where code lives before M12–M13 touch the same files, so they are moved once, not twice.
- The two-manifest split keeps the only line that matters for CI (Linux-buildable vs not) and drops the rest of the
  per-package cost; target dependencies give the same compile-time boundary as package dependencies.
- The same area names across layers make the codebase navigable for a solo maintainer and for agents with little context.

## Trade-offs
- One large `Package.swift` per side instead of small ones; merge conflicts move into it (rare, at solo scale).
- Step 4 rewrites every path: open branches must rebase, and `git log --follow` is needed for file history.
- `check_boundaries.py` and `prepush.sh` must learn target-level rules; CI workflows change paths.

## Consequences
- Updates in the same change as each step: MODULE_BOUNDARIES §1–2, AGENTS.md §5 and §13 paths, ADR-0008 (status note),
  `ios/project.yml`, `scripts/prepush.sh`, `scripts/check_boundaries.py`, `.github/workflows/swift-linux.yml`, DEVELOPMENT_SETUP.
- `HaloBotRendering`, `FeatureComposer` and `FeatureProfile` stop being paper modules.

## Verified facts and assumptions
- Line counts, file locations, folder sizes and missing paths were read from the working tree at `8da66aa` on 2026-11-22.
- Not yet checked: that moving the features into one manifest changes build and SwiftUI-preview behaviour only in paths. Step 4's
  pull request checks it with the app build and `prepush.sh`; a failure blocks that step only.
