# UX and ship-readiness audit (2026-11-22)

What stands between today's build (M0–M10 done, see [../ROADMAP.md](../ROADMAP.md)) and an app that **feels like an Apple-native
app** (**[DECISION D84]**) and can ship to external TestFlight and the App Store. Each finding names its evidence in the code at
commit `8da66aa`, the rule it breaks, and the roadmap item that fixes it. The 2026-11-25 gaps are in [../ROADMAP.md](../ROADMAP.md) §2 (GA-*); this file keeps what only a UX audit shows. Close a finding by ticking its roadmap
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
| UX-04 | Blocker | Sign-in artwork pending Q-BRAND (founder's halo disc `AppIcon` and `Assets.xcassets` landed in M11) | `ios/App/Resources/Assets.xcassets`; `FeatureOnboarding/SignInView.swift` | App Store submission; DESIGN_SYSTEM §5 | M22-6, Q-BRAND (👤) |
| UX-17 | High | Videos and voice notes leave the chat for Quick Look; polls can't be answered; no camera | GA-18, GA-19, GA-20 | Familiar patterns (§1.3) | M20-2…M20-5 |
| UX-18 | High | Links to people and rooms leave the app | GA-14 | NAVIGATION §3 | M18-9 |
| UX-20 | Medium | Animations mostly bypass `HaloMotion`; Reduce Motion is read in two views and for stickers; contrast is handled only by the colour tokens, Reduce Transparency and Bold Text nowhere | GA-25 | DESIGN_SYSTEM §6, AC-MOT-2 | M21-3 |

## 3. Findings — ship readiness

| ID | Sev. | Finding | Fix |
|---|---|---|---|
| SR-02 | Blocker | Push gateway for Beta/Release, APNs keys and TestFlight are not configured (R-24) | M22-1, 👤 |
| SR-03 | Blocker | Legal review (D38), export compliance (V-LEGAL) and App Store privacy labels ([../security/PRIVACY.md](../security/PRIVACY.md) §5) not done | M22-3, M22-4, 👤 |
| SR-07 | Blocker | No way to report content (App Review 1.2) | M20-7 |
| SR-08 | Blocker | Classic sync unmeasured on large accounts | M17-4, G-SCALE |
| SR-04 | High | No App Store Connect metadata: name, subtitle, keywords, screenshots (6.9" and 6.3"), support URL, privacy-policy URL (Q-APPSTORE) | M22-6, M22-8, 👤 |
| SR-06 | Medium | NFR-1 cold launch (0.357 s responsive) and timeline peak memory (76.8 MB) measured on iPhone 16 (`TEST_STRATEGY.md` §7); NFR-2 scroll hitch ratio (`XCTOSSignpostMetric`) and 300-room scale still need interactive Xcode/Instruments + MetricKit check | M17-5, M19-8, 📱 |

## 4. What is already good (keep it)
`ContentUnavailableView` for empty states (16 uses), `.searchable` lists, swipe actions and context menus on rows, `ShareLink`
exports, Quick Look for files, a Messages-style composer pill (`FeatureTimeline/TimelineView.swift:344`), honest send states,
the privacy blur (D61), and a typed navigation path. The polish work builds on these rather than replacing them.
