# ADR-0025: The composer stays in FeatureTimeline

- **Status:** Accepted (founder, 2026-11-27) — supersedes the `FeatureComposer` part of [ADR-0022](0022-module-layout-v2.md)
- **Date:** 2026-11-27
- **Decision IDs:** D127
- **Validation:** none — records where the code already is; checked by `scripts/check-boundaries.sh`

## Context
ADR-0022 (D86) planned a `FeatureComposer` module for "composer, attachments, mentions", split out of `FeatureTimeline`
before M13. The module was created (`ios/Packages/HaloApple/Sources/FeatureComposer/ComposerBar.swift`), but the composer
the app uses grew in `FeatureTimeline` instead: `TimelineComposer.swift`, `ComposerPanels.swift`, `ArticleComposer.swift`,
`CameraCapture.swift`, `VoiceRecorder.swift`, with its state (draft, mentions, pending photos and videos, sends) in
`TimelineViewModel`. The keyboard/panel area lives in `HaloDesignSystem/InputPanel/` (D97, D102).

## Problem
The [architecture audit](../ARCHITECTURE_AUDIT.md) (2026-11-27, F-04) found that nothing outside `FeatureComposer` uses its
public types; `App/HaloApp.swift` imports the module and uses nothing from it. The docs therefore point contributors and
agents at dead code whenever "the composer" is mentioned.

## Considered alternatives
1. **Keep ADR-0022 and move the composer into `FeatureComposer`.** Rejected for now: the composer sends through the room's
   `TimelineCoordinator`, edits and replies target timeline rows, and the input area is tied to the timeline's scroll and
   keyboard handling (D97, D102). A separate module would need a new interface between two features, which AGENTS §17
   forbids importing each other, so the interface would have to go through `HaloApplication`, for no user-visible gain.
2. **Record the composer where it is (chosen).**

## Decision
**[DECISION D127]** The message composer (text, mentions, attachments panel, camera, voice, article, sends) belongs to
`FeatureTimeline`. `FeatureComposer` is retired: no new code goes into it, and it is removed (module, product, app import,
`FeatureComposerTests`) in a later code change.

## Rationale
- The code already lives there; the decision makes the docs true instead of moving ~2,000 lines.
- The composer's state and the timeline's state change together in almost every M20 feature.

## Trade-offs
- `FeatureTimeline` stays the largest feature module. Splitting `TimelineViewModel` into owned child models (composer,
  bot tasks, media playback; audit F-08) inside the same module is the intended way to keep it manageable.

## Consequences
- MODULE_BOUNDARIES §1 lists the composer under `FeatureTimeline` and marks `FeatureComposer` retired.
- Follow-up code change: delete `FeatureComposer` (`Package.swift` product and targets, `ios/project.yml`, the import in
  `App/HaloApp.swift`) and this ADR's "retired" note in MODULE_BOUNDARIES.

## Verified facts and assumptions
- [VERIFIED] On `main` at `2b98ee7`, a search for `ComposerBarView`, `ComposerRules` and `ComposerPendingPhoto` outside
  `Sources/FeatureComposer` finds no use; the only reference to the module is `import FeatureComposer` in `App/HaloApp.swift:3`.
