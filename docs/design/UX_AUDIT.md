# UX and ship-readiness audit (2026-11-22)

What stands between today's build (M0–M10 done, see [../ROADMAP.md](../ROADMAP.md)) and an app that **feels like an Apple-native
app** (**[DECISION D84]**) and can ship to external TestFlight and the App Store. Each finding names its evidence in the code at
commit `8da66aa`, the rule it breaks, and the roadmap item that fixes it (M11–M15). Close a finding by ticking its roadmap
item; remove it from this file when the item is merged.

Severity: **Blocker** (no external release without it) · **High** (users notice in the first five minutes) · **Medium** (daily
friction or a broken spec promise) · **Low** (polish).

## 1. North star: "like an Apple app" (D84)
Halo should be indistinguishable in feel from Messages, Mail and Photos while keeping its own identity (colour, icon, artwork —
[DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) §1, D37). In practice that means:

1. **System components first.** `List`, `NavigationStack`, `.searchable`, `.swipeActions`, `.contextMenu`,
   `ContentUnavailableView`, `ShareLink`, `PhotosPicker`, Quick Look, `.sheet` detents. A custom control needs a written reason.
2. **iOS 26 design language.** Let bars, toolbars, sheets and menus take the system Liquid Glass material automatically (ADR-0014:
   iOS 26 minimum); no opaque custom backgrounds behind bars; floating controls (composer, jump pills) use system materials.
3. **Familiar patterns.** Compose button top-trailing, large titles on roots, swipe with icon + label, long-press menus with
   previews, pull to refresh where data can be refreshed, haptics where Messages gives them.
4. **Text is Apple text.** Dynamic Type styles only, SF Symbols only, sentence-case labels, Apple's tone (short, plain, no blame).
5. **Respect the system.** Dark mode, Increase Contrast, Reduce Motion, Reduce Transparency, Bold Text, VoiceOver, Voice Control,
   Low Power Mode, Focus, notification settings.

## 2. Findings — UX

| ID | Sev. | Finding | Evidence | Breaks | Fix |
|---|---|---|---|---|---|
| UX-04 | Blocker | Sign-in artwork pending Q-BRAND (founder's halo disc `AppIcon` and `Assets.xcassets` landed in M11) | `ios/App/Resources/Assets.xcassets`; `FeatureOnboarding/SignInView.swift` | App Store submission; DESIGN_SYSTEM §5 | Q-BRAND (👤) |
| UX-16 | Low | No system integrations users expect from a native messenger: share extension, App Intents / Siri, Spotlight, Focus filter, Live Activity for uploads | none present | NAVIGATION §3 (share extension P2) | Post-1.0 (M16 backlog) |

## 3. Findings — ship readiness

| ID | Sev. | Finding | Fix |
|---|---|---|---|
| SR-02 | Blocker | Push gateway for Beta/Release, APNs keys and TestFlight are not configured (R-24) | M5 leftover, 👤 |
| SR-03 | Blocker | Legal review (D38), export compliance (V-LEGAL) and App Store privacy labels ([../security/PRIVACY.md](../security/PRIVACY.md) §5) not done | M15, 👤 |
| SR-04 | High | No App Store Connect metadata: name, subtitle, keywords, screenshots (6.9" and 6.3"), support URL, privacy-policy URL (Q-APPSTORE) | M15, 👤 |
| SR-06 | Medium | Performance targets NFR-1/NFR-2 need physical-device measurement with XCTest metrics (`testLaunchPerformanceMetric` in place) | M15, 📱 |

## 4. What is already good (keep it)
`ContentUnavailableView` for empty states (16 uses), `.searchable` lists, swipe actions and context menus on rows, `ShareLink`
exports, Quick Look for files, a Messages-style composer pill (`FeatureTimeline/TimelineView.swift:344`), honest send states,
the privacy blur (D61), and a typed navigation path. The polish work builds on these rather than replacing them.
