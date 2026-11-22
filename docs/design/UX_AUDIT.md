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
| UX-01 | High | Starting a chat is only possible from **Settings** ("Find a person or create a room"); the room list has no compose button | `FeatureSettings/SettingsView.swift:117`; `App/HaloApp.swift:118` | SCREEN_SPECIFICATIONS S3 header; Messages/Mail pattern | M12 |
| UX-02 | High | App shell is unplanned (D50 asked for tabs; D85 now chooses a single stack): one `NavigationStack`, Settings behind the avatar, Search / Activity / Stickers library only as sheets, no tab bar; the room list has an empty title | `App/HaloApp.swift:69-175` (`.navigationTitle("")` at line 75) | D50, NAVIGATION §1 | M12 (D85: single stack decided) |
| UX-03 | High | Design tokens of DESIGN_SYSTEM §2 don't exist: no asset catalogue colours, no contrast test (promised for M0); 38 raw system colours (`.blue`, `.yellow`, `.orange`, `.indigo`, …) and 12 fixed font sizes in features/app | `grep` over `ios/Packages/Features`, `ios/App`; `HaloDesignSystem` has 4 files and none are tokens | DESIGN_SYSTEM §2–3, §7 | M11 |
| UX-04 | Blocker | No asset catalogue and **no app icon**; sign-in shows an SF Symbol as the logo | no `*.xcassets` under `ios/`; `FeatureAuth/SignInView.swift:15` | App Store submission; DESIGN_SYSTEM §5 | M11 + Q-BRAND |
| UX-05 | High | Components of DESIGN_SYSTEM §7 (`RoomRow`, `UnreadIndicator`, `Banner`, `LoadingState`, `ErrorState`, …) live inline in feature views, so the same thing looks different on different screens | `FeatureRoomList/RoomListView.swift:97-139` builds rows inline | DESIGN_SYSTEM §7 | M11 |
| UX-06 | Medium | First load shows a centred spinner instead of skeleton rows; 24 bare `ProgressView()` across features | `FeatureRoomList/RoomListView.swift:32` | DESIGN_SYSTEM §8 ("no spinners for lists") | M11, M13 |
| UX-07 | Medium | Notification permission is asked the moment sign-in finishes, with no explanation; a denial is hard to undo and push is a P0 feature | `App/HaloApp.swift:234-239` | HIG (ask in context) | M13 (S14 priming) |
| UX-08 | Medium | No state restoration: relaunch never returns to the open room | 0 `@SceneStorage` | NAVIGATION §4 | M12 |
| UX-09 | Medium | No haptics anywhere (send, reaction, swipe threshold, verification success) | 0 `sensoryFeedback` | D84 §1.3 | M11 (`HaloFeedback`), M13 |
| UX-10 | High | Accessibility is unverified: 36 `accessibilityLabel`s, no VoiceOver pass, no AX5 Dynamic Type check, no automated audit; custom rows don't combine elements | NFR-6 never measured | NFR-6, DESIGN_SYSTEM §9 | M14 |
| UX-11 | High | Not localisation-ready: no String Catalog, view-model strings are plain `String`s, plurals built by hand (`members == 1 ? …`) | `FeatureRoomList/RoomListView.swift:83`; no `*.xcstrings` | NFR-9 | M14 (Q-L10N) |
| UX-12 | Low | Swipe actions are text-only with ad-hoc tints; Mail uses icon + label with consistent semantic colours | `FeatureRoomList/RoomListView.swift:117-124` | D84 §1.3 | M13 |
| UX-13 | Low | Media Gallery preset row uses a hand-made blue/indigo gradient instead of tokens | `FeatureRoomList/RoomListView.swift:39-52` | DESIGN_SYSTEM §2 | M11 |
| UX-14 | Medium | Sign-in starts with a bare "Server" field; no explanation of a homeserver, no suggested server, no "what's Matrix" help | `FeatureAuth/SignInView.swift:21-30` | S1 spec ("value statement") | M13 (Q-ONBOARD-SERVER) |
| UX-15 | Medium | Errors are shown as developer text in places (adapter error descriptions reach alerts); there is no voice-and-tone guide | 9 `.alert(` call sites | Honest UI, D84 §1.4 | M13 (copy pass) |
| UX-16 | Low | No system integrations users expect from a native messenger: share extension, App Intents / Siri, Spotlight, Focus filter, Live Activity for uploads | none present | NAVIGATION §3 (share extension P2) | Post-1.0 (M16 backlog) |

## 3. Findings — ship readiness

| ID | Sev. | Finding | Fix |
|---|---|---|---|
| SR-01 | Blocker | No privacy manifest (`PrivacyInfo.xcprivacy`) for the app and NSE, although both use required-reason APIs (`UserDefaults`, file timestamps) | M15 |
| SR-02 | Blocker | Push gateway for Beta/Release, APNs keys and TestFlight are not configured (R-24) | M5 leftover, 👤 |
| SR-03 | Blocker | Legal review (D38), export compliance (V-LEGAL) and App Store privacy labels ([../security/PRIVACY.md](../security/PRIVACY.md) §5) not done | M15, 👤 |
| SR-04 | High | No App Store Connect metadata: name, subtitle, keywords, screenshots (6.9" and 6.3"), support URL, privacy-policy URL (Q-APPSTORE) | M15, 👤 |
| SR-05 | High | No in-app path for beta feedback; testers must find the diagnostics export themselves | M15 |
| SR-06 | Medium | Performance targets NFR-1/NFR-2 were never measured on a device with XCTest metrics | M15 |
| SR-07 | Medium | No UI smoke test (XCUITest) of the golden path; BUILD_AND_RELEASE §4 step 1 asks for one | M14 |

## 4. What is already good (keep it)
`ContentUnavailableView` for empty states (16 uses), `.searchable` lists, swipe actions and context menus on rows, `ShareLink`
exports, Quick Look for files, a Messages-style composer pill (`FeatureTimeline/TimelineView.swift:344`), honest send states,
the privacy blur (D61), and a typed navigation path. The polish work builds on these rather than replacing them.
