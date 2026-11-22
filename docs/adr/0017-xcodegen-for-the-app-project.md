# ADR-0017: XcodeGen generates the app project

- **Status:** Accepted · **Date:** 2026-11-19 · **Decision IDs:** none (resolves Q-XCODEGEN; narrows ADR-0008 option 3) · **Validation:** none

## Context
ADR-0008 keeps all code in local Swift packages and the Xcode project only as a composition root, and rejected a project generator. In practice every new package, extension target or scheme meant editing `project.pbxproj`, which is error-prone; the project was regenerated twice with XcodeGen from a spec kept outside the repository.

## Problem
How is `ios/Halo.xcodeproj` kept correct as targets and package references change?

## Considered alternatives
1. Hand-edit the project (ADR-0008's stance).
2. **XcodeGen with a committed `ios/project.yml`; the generated project stays committed.**
3. Tuist.

## Decision
Option 2. `ios/project.yml` is the source of truth; `ios/Halo.xcodeproj` is generated from it with `cd ios && xcodegen --spec project.yml --project .` and committed so that a checkout builds without XcodeGen. Packages stay the unit of code (ADR-0008 is otherwise unchanged).

## Rationale
The spec is short and reviewable; the generated project no longer drifts; the tool is small and has no runtime footprint. Tuist is more than this project needs.

## Trade-offs
One more tool (`brew install xcodegen`). Settings that Xcode writes into the project (for example the development team) are lost on regeneration, so they live in the spec, an xcconfig, or on the command line instead.

## Consequences
Change targets, dependencies or schemes in `project.yml` and regenerate in the same commit. The development team is not in the spec (it is personal): set it in the git-ignored `ios/Config/Local.xcconfig` (see `Local.xcconfig.example`) or pass `DEVELOPMENT_TEAM=<id>`.

## Verified facts and assumptions
[VERIFIED locally] XcodeGen regenerates the current project, which builds for the iOS Simulator.
