# Roadmap

**Where we are (2026-11-22):** all autonomous engineering work across **M0–M16** (including **ADR-0022 steps 1–4**, D84–D96, and **Tech Debt Phases A–D**) is complete! Only founder (`👤`) and physical-device (`📱`) items remain (listed in `HANDOFF.md` §5). Evidence: [design/UX_AUDIT.md](design/UX_AUDIT.md); bar: "Ship-ready definition" below.

Capacity: solo, part-time (D24). Estimates are calendar weeks at ~15 h/week and are **[ASSUMPTION]**s. Each milestone ends with its exit criteria **verified by tests** (AGENTS.md §0, §12).

## Remaining work (the loop's queue)
Ordered work queue for the autonomous loop ([development/AUTONOMOUS_LOOP.md](development/AUTONOMOUS_LOOP.md), D70). Take the first unchecked item the agent can do; items marked 📱 need a physical device and 👤 the founder (they go to HANDOFF §5 and don't block the queue). Completed M0–M10 history lives in the "Done (M0–M10)" appendix below (TD-09).

**M4 / M5 leftovers**
- [ ] Simulator UI check of the sticker panel and pack creation; real sticker images loaded from media.
- [ ] (deferred, D71, not blocking) CI: macOS job for Mac-only packages and app build (Q-CI-MAC).
- [ ] 👤 Push gateway (Sygnal + pushkin) for Beta/Release, APNs keys, TestFlight build.
- [ ] 👤📱 AC-U8: 7-day soak with zero unexplained auditor findings.

**M11 Design-system foundation** (D84; exit: AC-UX-1, AC-UX-2; done except 👤 Q-BRAND)
- [x] ADR-0022 step 1 (layout, D86): stale paths fixed in `AGENTS.md`; `TimelineReadTracker` + pure tests moved to `HaloDomain/ReadState/`; `HaloDesignSystem/{Tokens,Components,Media}/`; `ios/App/{Resources,Support}/` + `project.yml`.
- [x] Naming gate (MODULE_BOUNDARIES §1): `scripts/check_boundaries.py` enforces `Feature<Area>`, `Halo<Layer>`, and no module/type name collision, unit-tested in `scripts/test_check_boundaries.py`.
- [x] Asset catalogues: `HaloDesignSystem` `Colors.xcassets` (Light/Dark/Increase Contrast) and `ios/App/Resources/Assets.xcassets` (`AccentColor` + placeholder 1024 pt `AppIcon` light/dark/tinted until Q-BRAND).
- [x] `HaloDesignSystem` tokens (`HaloColor`, `HaloSpacing`, `HaloRadius`, `HaloMotion`, `HaloTypography`) and WCAG AA contrast test (`ColorContrastTests`, AC-UX-2).
- [x] Shared components (`RoomRow`, `UnreadIndicator`, `HaloBanner`, `LoadingState`, `ErrorState`, `EmptyState`) with Light/Dark/AX5 `#Preview`s.
- [x] `HaloFeedback` mapping app events to `.sensoryFeedback`.
- [x] Replaced raw system colours and fixed font sizes across `Features/` and `ios/App/`; added `scripts/check-design-tokens.sh` to `scripts/prepush.sh` (AC-UX-1).
- [ ] 👤 Q-BRAND: final app icon and the sign-in illustration (original artwork, DESIGN_SYSTEM §5).

**M12 Navigation and information architecture** (exit: AC-UX-3, AC-UX-4; fixes UX-01, UX-02, UX-08; **done**)
- [x] ADR-0022 step 2 (D86): `ChatsRoute` + `ChatsRouter` in `HaloApplication/Navigation/` (unit-tested); `AppRoot` split into `App/Composition/{Session,Chats,Settings,Notifications,Bots}Assembly.swift`; extracted `FeatureSearch` and `FeatureProfile` with moved tests and `check-boundaries` green.
- [x] Q-NAV-SHELL decided by the founder (2026-11-22): single `NavigationStack`, Messages-style, no tab bar (D85, supersedes D50); NAVIGATION.md §1 rewritten.
- [x] Compose button (`square.and.pencil`, top-trailing) on the Chats root opens New chat as a sheet; the Settings "Find a person" row is removed (UX-01). Large title "Chats" on the root.
- [x] Shell per D85: one typed path `ChatsRoute` (`.room`, `.thread`, `.settings`, `.stickerLibrary`, `.activity`, `.globalMediaGallery`); Settings pushed from the avatar (`SettingsConfiguration` model factory replaces the 25-closure init); more menu (`ellipsis.circle`) with filters, Saved Messages, New chat and Activity (Stickers live in Settings); Activity and Sticker library pushed instead of sheets.
- [x] Search per D85: `.searchable` on the room list (room names while typing + `"Messages"` section from `SearchPort` via `MessageSearchResultsSection`), replacing the magnifying-glass sheet.
- [x] State restoration (NAVIGATION §4): navigation path persisted via `@SceneStorage`, dropping rooms no longer joined (`ChatsRouter.pruneInvalidRooms`).
- [x] Notification tap, `matrix:` links, search hits and Activity items route through `ChatsRouter` (no duplicated pushes); unit-tested in `HaloApplicationTests/ChatsRouterTests.swift`.

**M13 Core-flow polish — the first five minutes and the daily loop** (exit: AC-UX-5, AC-UX-6, AC-UX-7; fixes UX-06, UX-07, UX-09, UX-12, UX-14, UX-15; **done**)
- [x] ADR-0022 step 3 (D86, together with the TD-11 split): extracted `HaloBotRendering` (`BotCardView`, `HTMLText` + tests), `FeatureComposer` (`ComposerBarView` + `ComposerStateTests`), `FeatureMedia` (`GlobalMediaGallery` + unified `HaloDesignSystem.PagedPhotoViewer` + `QuickLookView`); renamed `FeatureAuth` → `FeatureOnboarding`; split `TimelineView` and `TimelineViewModel` into files < 500 lines each.
- [x] First run (S1, S14, S15): `SignInView` value statement + inline `"What's a homeserver?"` help; `NotificationPrimingView` (S14, replaces immediate auto-prompt in `HaloApp`, AC-UX-7); `FirstRunChecklistView` (S15).
- [x] Room list: skeleton rows (`LoadingState`), `.refreshable` sync round trip, Mail-pattern swipe actions with SF Symbols + labels and semantic tints (`UnreadIndicator`, `RoomRow`).
- [x] Timeline: continuous bubble corners, swipe-to-reply gesture with `HaloFeedback(.swipeThreshold)`, double-tap quick reaction 👍 with `HaloFeedback(.reaction)`, `.regularMaterial` jump pills without custom shadows.
- [x] Composer: 6-line growth (`ComposerRules.maxLineCount = 6`), attachment menu (Photos, Files, Paste image, Stickers), `HaloFeedback(.send)`.
- [x] Room details: removed 1.5 s sleep workaround (TD-13); pull-to-refresh updates permissions cleanly.
- [x] Copy pass (UX-15): `HaloErrorCopy` in `HaloDomain` maps every `HaloError` case to a plain, actionable sentence (unit-tested in `HaloErrorCopyTests`).
- [x] Simulator verification of M11–M13 on `iPhone Air` (Light, Dark, AX5).

**ADR-0022 step 4 — two-manifest consolidation** (D86; **done**)
- [x] `ios/Packages/HaloCore` (HaloFoundation, HaloDomain, HaloApplication, HaloTestSupport — Linux) and `ios/Packages/HaloApple` (adapter, persistence, platform, design system, bot rendering, every feature as a target) replace the 20 manifests; module and target names unchanged (MODULE_BOUNDARIES §1).
- [x] Same area folders in `HaloMatrixAdapter` and `HaloTestSupport` as in `HaloDomain`/`HaloApplication` (`Session`, `Sync`, `RoomList`, `Timeline`, `Media`, `Stickers`, `Encryption`, `Notifications`, `Bots`, `Search`, `Account`, `Support`).
- [x] Tooling and docs updated: `ios/project.yml`, `scripts/prepush.sh`, `scripts/check_boundaries.py` (target-level rules, same `Feature` prefix), `.github/workflows/swift-linux.yml`, MODULE_BOUNDARIES §1–2, AGENTS.md §5/§13, DEVELOPMENT_SETUP, ADR-0008 status note.

**M14 Accessibility and localisation** (exit: AC-UX-8, AC-UX-9, AC-UX-10; fixes UX-10, UX-11, SR-07; done except 👤 Q-L10N)
- [x] VoiceOver pass per DESIGN_SYSTEM §9: `RoomRow` reads as one combined element (`RoomRow.accessibilitySummary`, unit-tested), custom `.accessibilityActions` on room rows (Mark read/unread, Mute, Favourite) and timeline rows (Reply, React 👍, More reactions, Edit, Delete), `BotCardView` 44×44 hit targets and explicit state values.
- [x] Dynamic Type up to AX5 verified (replaced clipped `.roundedBorder` fields in `SignInView` with Dynamic-Type-friendly containers, `RoomRow` AX5 vertical reflow, zero audit issues).
- [x] XCUITest target `HaloUITests` (`ios/UITests/HaloUITests.swift`, TD-03): automated `performAccessibilityAudit()` on root and inline-help screens + optional golden path against `infra/dev`; wired into `scripts/prepush.sh`.
- [x] String Catalog `ios/App/Resources/Localizable.xcstrings` with English source language and plural rules (`%lld unread messages`, `%lld members`), validated by `RoomRowAccessibilityTests.stringCatalogIsValid`.
- [ ] 👤 Q-L10N: languages for the external beta (recommendation: English only for Beta 1, then the founder's languages).

**M15 Ship readiness — external TestFlight and App Store** (exit: AC-UX-11, AC-UX-12 and the "Ship-ready definition" below; fixes SR-01, SR-05; done except 👤/📱 items)
- [x] `PrivacyInfo.xcprivacy` for the app (`ios/App/Resources/`) and the NSE (`ios/NotificationService/`) declaring required-reason APIs (`UserDefaults`, `FileTimestamp`, `DiskSpace`), `NSPrivacyTracking = false`, no collected data; validated in `AcknowledgementsTests.privacyManifestsAreValid`.
- [x] In-app feedback: Settings → "Send feedback" (`FeedbackSheetView`) opens a share sheet with optional, opt-in diagnostics `.zip` (never automatic; PRIVACY §1); TestFlight screenshot feedback mentioned in What's New.
- [x] "What's New" sheet (`WhatsNewView`) shown once per marketing version via `PreferencesPort.lastSeenWhatsNewVersion`, plus About section links (Privacy policy, Support, What's New).
- [ ] 📱 Performance budgets on a physical device with XCTest metrics (`testLaunchPerformanceMetric` in `HaloUITests` ready; cold start ≤ 1 s for 300 rooms NFR-1, scroll hitch < 5 ms/s NFR-2, memory < 200 MB, MetricKit reports need physical device).
- [ ] 👤 Q-APPSTORE: name, subtitle, category, age rating, keywords; screenshots (6.9" and 6.3", light and dark) generated from the M14 UI test with fixture data; support and privacy-policy pages.
- [ ] 👤 Legal review (D38), export compliance (V-LEGAL), privacy nutrition labels (PRIVACY §5), Q-SDK-BUILD and Q-CRASH decided before external testers.
- [ ] 👤📱 Beta 1 (internal TestFlight) → Beta 2 (external TestFlight, ≤ 25 trusted testers) → 1.0 App Store, per the release plan below.

**Tech debt (paid down alongside M11–M15; scores and evidence in [development/TECH_DEBT.md](development/TECH_DEBT.md))**
- [x] Phase A with M11: `.swift-format` + `.swiftlint.yml` enforced by `prepush.sh` (TD-06, D62); `@unchecked Sendable` justifications added (TD-14); roadmap queue slimmed to one-line items with M0–M10 history in the appendix below (TD-09).
- [x] Phase B with M11–M12: `PreferencesPort` + observable `PreferencesStore`, no `AppPreferences()` in `ios/App/` (TD-02); `AppRoot` split into `ios/App/Composition/*Assembly.swift` (≤ 300 lines) and `SettingsView` built from `SettingsConfiguration` model factory (TD-10).
- [x] Phase C with M13: `HaloErrorCopy` user-facing error map (TD-01/UX-15); `ActionState` double-tap guard helper (TD-07, unit-tested); split `TimelineViewModel`/`TimelineView` below 500 lines per file (TD-11); removed 1.5 s sleep workaround in room details (TD-13).
- [x] Phase D with M14–M15: `HaloUITests` (TD-03); manual-dispatch macOS build workflow `.github/workflows/macos-build.yml` (TD-04); `bot_action` table (`v9-bot-action` + `BotActionStore` + tests, TD-08).
- [x] ADR-0022 (module layout v2, TD-16) accepted by the founder (2026-11-22, D86); its four steps are queued in M11, M12, M13 and "ADR-0022 step 4" above.
- [ ] 👤 TD-12 (R-16 field encryption) and 📤 TD-15 (upstream SDK filter / queued raw sends).

## Ship-ready definition (D84)
Halo is ready for external testers when **all** of these hold; each line names how it's checked.

| Area | Bar | Check |
|---|---|---|
| Correctness | AC-U1–U7 green; AC-U8 soak with zero unexplained auditor findings | Scenario suite, auditor |
| Native feel | No raw colours or fixed font sizes outside `HaloDesignSystem`; every screen uses system navigation, bars and sheets | AC-UX-1, `check-design-tokens.sh` |
| First five minutes | Install → signed in → verified → first message sent in ≤ 3 minutes for a tester with an account, no dead ends | AC-UX-5, moderated test with 3 people |
| States | Every screen has loading, empty and error states from DESIGN_SYSTEM §8; no blank screen, no spinner for lists | AC-UX-6 |
| Accessibility | Zero issues from `performAccessibilityAudit()` on root screens; AX5 usable; VoiceOver golden path | AC-UX-8, AC-UX-9 |
| Performance | NFR-1, NFR-2 met on an iPhone 15-class device | AC-UX-11 |
| Stability | Crash-free sessions ≥ 99.5 % over the internal beta; no hang > 2 s in MetricKit | TestFlight + MetricKit |
| Compliance | Privacy manifest, privacy labels, export compliance, licence gate, legal review | AC-UX-12, BUILD_AND_RELEASE §4 |

**M16 Post-1.0 backlog** (first item picked by the founder, 2026-11-22)
- [x] Share extension (D87): `HaloShareExtension` stages text, a link, photos and files into the App Group `share-inbox/` (`FileShareInbox`); the app shows "Send to…" on activation (`ShareHandoffViewModel`, `ShareTargetPickerView`) and `ShareCoordinator` sends through the timeline path. Tests: `ShareCoordinatorTests`, `FileShareInboxTests`, `ShareHandoffViewModelTests`; privacy manifest checked in `AcknowledgementsTests`.
- [x] App Intents + Spotlight (D88): opt-in "Chats in Siri and Spotlight"; `OpenChatIntent` / `ChatEntity` (Siri phrase "Open <chat> in Halo"), Spotlight results open the chat. Tests: `ChatShortcutPublisherTests`, `SystemChatShortcutStoreTests`, `AppPreferencesTests`.
- [x] Share sends from the share sheet (D92, ADR-0023): `MatrixShareTargetPort`, `SendConfirmation`, `ShareCoordinator.deliver(confirmingFor:)`, extension picker via `ShareTargetPickerView`; fallback to staging + notification. Tests: `SendConfirmationTests`, `ShareTargetTests`, `ShareCoordinatorTests`.
- [ ] 📱 V-SHARE-1: encrypted-room send from the extension on a device.
- [ ] 📱 Share extension on a physical device: the App Group container is shared only in signed builds; check Safari (link), Photos (several photos), Files (PDF) and a > 50 MiB file end to end.
- [x] Unread widget (D89): `HaloWidgetExtension`, small and lock-screen families, count only; `UnreadWidgetSnapshot` tests, privacy manifest check.
- [x] Focus filter (D90): `HaloFocusFilter` + `FocusChats`; room list `effectiveFilter` with a "Show all chats" banner; `RoomListFocusTests`, `FocusChatsTests`.
- [x] iPad layout (D91): iPhone + iPad target, split view with the chat list as sidebar, `ChatsRouter.replacesDetail` + `ChatsRouterSplitTests`, readable sign-in column. Built and launched on iPad Pro 13-inch (M5) simulator (sign-in only; signed-in needs a homeserver).
- [ ] 📱 iPad on a device or with the dev homeserver: sidebar selection, collapse in Slide Over / Split View, rotation, Settings and Stickers in the detail column.
- [ ] 📱 Focus filter on a device: add Halo to a Focus, turn it on and off, check the list narrows and restores.
- [ ] 📱 Widgets on a device: add the small and lock-screen widgets, receive a push and check the count refreshes.
- [ ] 📱 App Intents on a device: the Siri phrase and a Spotlight result opening a chat (the simulator can't speak to Siri).
- [x] Unread chats widget (D93): medium widget, names from the D88 opt-in; `UnreadChatsSnapshot` tests.
- [x] Hardware-keyboard shortcuts (D91 extras): ⌘N new chat, ⌘, settings, ⌘F search, ⌘1–⌘6 filters (`HaloApp.swift`); no unit test (SwiftUI wiring), built for iPad simulator.
- [x] Drag and drop into a conversation (`TimelineDropModifier`, `DropClassifier`): pictures join the pending photos, other files send at once (≤ 50 MiB), text and links go into the draft; a tinted border shows the target. `TimelineDropTests`.
- [x] Drag and drop out of a conversation (`TimelineDragExtractor`, `DraggedTimelineFile`): drag message text/captions/notices/emotes, loaded photos (not stickers), and file attachments (≤ 50 MiB, sanitized temp file) out to other apps or Halo windows. `TimelineDragTests`.
- [ ] 📱 Drag and drop on an iPad: from Photos, Files and Safari into an open chat, and dragging text/photos/files out of a chat (also between Halo and another app in Split View).
- [x] Send-by-Siri (`SendMessageIntent`, `SiriSendCoordinator`, builds on D88): reuses the opt-in `ChatEntity` list, asks for Siri confirmation before sending, restores the session if woken in the background, sends through the normal timeline path and speaks honestly whether confirmed or queued. `SiriSendCoordinatorTests`.
- [ ] 📱 Send-by-Siri on a device: turn on "Chats in Siri and Spotlight", then say "Send a message to <chat> in Halo" and confirm; check both online (confirmed) and offline (queued).
- [x] iPad three-column layout (`RoomInfoPresentation`, `TimelineScreen` `.inspector` column): on regular-width iPad, tapping the room title/avatar or pressing ⌘I docks Room info as a trailing third column (300–420 pt); compact iPad windows and iPhone keep the modal sheet. `ChatsRouterSplitTests`.
- [ ] 📱 iPad three-column inspector on a device: toggle Room info with the top-bar button and ⌘I in full screen and Split View, check rotation and Slide Over collapse to a sheet.
- Calls: will not be implemented (D94, founder).

## Release plan
| Release | Contents | Audience | Entry |
|---|---|---|---|
| **Beta 1** (internal TestFlight) | M0–M10 + M11 + M12 + push gateway (R-24) | Founder + 1–3 people | M12 merged, Beta push gateway live |
| **Beta 2** (external TestFlight) | + M13, M14, M15 compliance items | ≤ 25 trusted testers | Ship-ready definition met except the 1.0-only lines |
| **1.0** (App Store) | + fixes from Beta 2, final icon/screenshots, legal sign-off | Public (Matrix power users) | Two weeks of Beta 2 with no P0/P1 bug open |
| **Post-1.0 backlog (M16)** | Share extension (done, D87), App Intents / Siri and Spotlight (open chat done, D88), widgets (unread count done, D89), Focus filter, widgets, iPad layout (calls dropped, D94) | — | Re-plan after 1.0 |

## Milestones

```mermaid
gantt
  dateFormat  YYYY-MM-DD
  axisFormat  %b
  section MVP
  M0 Foundation          :m0, 2026-12-01, 4w
  M1 Read-only client    :m1, after m0, 7w
  M2 Messaging           :m2, after m1, 7w
  M3 Read-state engine   :m3, after m2, 7w
  M4 Stickers v1         :m4, after m3, 5w
  M5 MVP hardening       :m5, after m4, 5w
  section P2
  M6 Bot cards           :m6, after m5, 4w
  M7 Bot Activity        :m7, after m6, 4w
  M8 Search + Saved      :m8, after m7, 6w
  M9 Gallery + Export    :m9, after m8, 5w
  M10 Threads            :m10, after m9, 6w
  section Ship (D84)
  M11 Design system      :m11, 2026-11-23, 2w
  M12 Navigation         :m12, after m11, 2w
  M13 Core-flow polish   :m13, after m12, 3w
  M14 Accessibility+L10n :m14, after m11, 4w
  M15 Ship readiness     :m15, after m13, 2w
```

| # | Milestone | Scope | Exit criteria | Gates |
|---|---|---|---|---|
| M0 | Foundation | Repo layout, Xcode project + local packages, `infra/dev` Synapse (native password login, D64)/Sygnal, prebuilt SDK pinned, adapter skeleton behind ports, licence gate, CI (docs + Linux Swift domain tests), logging | Password login against the dev Synapse shows the room count via ports; CI green | V-SDK-1, V-SQL-1, V-CI-1, V-APPLE-1 |
| M1 | Read-only client | Session restore, `SyncService`, room list, timeline (text, notices, images, UTD), verification + recovery, NSE spike | All rooms readable; encrypted push shown | **G-NSE** (AC-NSE-1…6) |
| M2 | Messaging | Composer, replies, edits, deletes, reactions, typing, receipts display, send queue, media display, image send | Daily use alongside Element X; AC-M* | — |
| M3 | Read-state engine | `ReadState` policy, receipt outbox, visibility tracking, badge, clearing, marked-unread, modes, auditor, Synapse scenario suite | AC-U1–U7 automated green | **G-UNREAD, G-FFI** |
| M4 | Stickers v1 | Image-pack discovery, panel, favourites/recents, search, send/render, personal pack creation | AC-S* | V-ST-1 |
| M5 | MVP hardening | OIDC/MAS login (MAS added to `infra/dev`, V-AUTH-1), settings, acknowledgements, generic bot rendering, performance, 7-day soak | **MVP: daily-driver switch**, AC-U8 | — |
| M6 | Bot cards | Template parsers v1, task→event index, reaction protocol | AC-B* | — |
| M7 | Bot Activity tab | Task aggregation, filters, jump to source | AC-A* | — |
| M8 | Search + Saved | Evaluate `SearchService` → decide; Saved room | Known message found in an E2EE room | V-SEARCH-1 |
| M9 | Gallery + Export | Media index, gallery, encrypted export | — | — |
| M10 | Threads | Thread UI + per-thread read state | Unread scenarios with threads green | — |
| M11 | Design-system foundation | Asset catalogue, tokens, shared components, haptics, token gate | AC-UX-1, AC-UX-2 | Q-BRAND (icon only) |
| M12 | Navigation & IA | Single-stack shell (D85), compose button, more menu, searchable list, state restoration, unified routing | AC-UX-3, AC-UX-4 | — |
| M13 | Core-flow polish | First run, permission priming, room list/timeline/composer/details polish, copy pass | AC-UX-5–AC-UX-7 | Q-ONBOARD-SERVER |
| M14 | Accessibility & localisation | VoiceOver/AX5 pass, UI tests + accessibility audit, String Catalog | AC-UX-8–AC-UX-10 | Q-L10N |
| M15 | Ship readiness | Privacy manifest, feedback, What's New, perf budgets, App Store metadata, legal | AC-UX-11, AC-UX-12, Ship-ready definition | Q-APPSTORE, V-LEGAL |

## Gates

| Gate | When | Question | Pass → | Fail → |
|---|---|---|---|---|
| **G-FFI** | End of M3 | Are the upstream FFI APIs enough for unread correctness, stickers (custom room state)? (NSE budget: G-NSE.) | Stay on the upstream binary framework | Build Halo-owned UniFFI bindings over `matrix-sdk`/`matrix-sdk-ui` in `core/` behind the same ports (ADR-0003); budget 6–10 weeks |
| **G-NSE** (ADR-0016) | End of M1, independent of G-FFI | Does the NSE meet AC-NSE-1…6 — memory, execution time, timeout handling, extension termination, network failures and fallback behaviour ([features/NOTIFICATIONS.md](features/NOTIFICATIONS.md) §11)? | Keep the NSE pipeline | Lightweight runtime, cached badge, SDK built without unneeded features (Q-SDK-BUILD moves to M2); Halo-owned bindings only if the binding layer is the measured cost |
| **G-UNREAD** | End of M3 | Does the reconciliation policy over SDK + server signals meet AC-U1–U7 in scenario tests? | Keep the policy layer | Add an independent recount (needs G-FFI fail path, or upstream fixes) |

## Dependencies

```mermaid
flowchart LR
  M0 --> M1 --> M2 --> M3 --> M5
  M2 --> M4 --> M5
  M3 --> M10
  M5 --> M6 --> M7
  M5 --> M8 --> M9
  M1 -. media cache .-> M4
  M10 --> M11 --> M12 --> M13 --> M15
  M11 --> M14 --> M15
  M5 -. push gateway .-> M15
```

## Technical risks per milestone
See [RISK_REGISTER.md](RISK_REGISTER.md). Highest: T-NSE (M1), T-RECEIPTS (M3), T-STATE (M4), and the capacity risk PROJ-1 across all milestones.

## Done (M0–M10)
Concise record of completed functional milestones (detailed history in `git log`, [CODEBASE_REVIEW.md](CODEBASE_REVIEW.md) and [testing/GATE_EVALUATION_M3.md](testing/GATE_EVALUATION_M3.md); TD-09).

- **M0 Foundation:** `infra/dev` Synapse + Postgres, local Swift packages, Xcode project (`project.yml`), pinned `MatrixRustSDK`, Keychain + log sink, licence/boundary/secret CI gates, password login + session restore.
- **M1 Read-only client:** classic sync + room list + timeline, recovery-key & SAS emoji/decimal verification, media thumbnails/Quick Look/preview policy, physical iPhone 16 **G-NSE** 100/100 soak pass (`F-DEV-1`/`F-DEV-2`).
- **M2 Messaging:** Markdown/HTML composer, send queue + offline/kill-relaunch resend, replies, edits, deletes, reactions, mentions, typing notices, drafts, photo captions, file/audio/video sending.
- **M3 Read-state engine:** `ReadStatePolicy` + `BadgeCalculator` (D82), classic sync unread evidence (D73/D74), identity/timeline-order read intents (D80/ADR-0020), GRDB outbox & `notification_record`, auditor + `.zip` diagnostics, P1–P11 & S01–S29 green against `infra/dev`; G-UNREAD/G-FFI recommended pass.
- **M4 Stickers v1:** pack discovery + legacy `im.ponies.*`, animated preview/autoplay (12-slot cap), favourites/recents/search, pack creation, unavailable-pack removal, encryption notice, hidden pack rooms.
- **M5 MVP hardening:** MAS/OIDC login (`infra/dev/smoke-mas.sh`), Settings v1 + acknowledgements + privacy toggles + app-switcher blur (D61), user profiles, room details/invites/new chat/paging, room list v2 filters & previews.
- **M6–M7 Bot cards & Activity:** Layer 2 template cards (`TodoListV1`, `TaskAddedV1`, `ReminderSetV1`, `TaskDoneV1`, `TaskDeletedV1`), allowlist sync, `bot_task` index + background scan, tick-from-Activity & source-redaction handling.
- **M8 Search + Saved:** `SearchPort` over SDK `SearchService`, message search sheet, Saved Messages room (`one.mbm.halo.saved_room`).
- **M9 Gallery + Export:** per-room gallery, Global Media Gallery preset virtual room (D83), passphrase-encrypted AES-256-GCM room export (D32).
- **M10 Threads:** `TimelinePort.openThread` over `TimelineFocus.thread`, "Reply in thread" action and thread sheet.
