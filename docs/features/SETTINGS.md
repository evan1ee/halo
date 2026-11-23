# Feature: Settings and Diagnostics

> Priority: P1 · Milestone: M5 (diagnostics in M3) · Modules: FeatureSettings · Requirements: R-P1-SET

## 1. Purpose
One place for account, notifications, privacy, appearance, storage, diagnostics and legal notices.

## 2. User stories
- I control receipts privacy, notifications defaults and media previews.
- I can export diagnostics when something looks wrong.
- I can read the open-source acknowledgements.

## 3. Functional requirements
| Section | Items |
|---|---|
| Account | Profile, sessions (built, read-only list, ADR-0018; signing others out not built), change password (built, ADR-0019), sign out |
| Security | Verification status (verify row, built), recovery key setup/change (built), key backup state |
| Notifications | Permission status, push health, defaults for DMs/groups (built: all messages / mentions and keywords), name and @room mention toggles (built), keyword rules (not built) |
| Privacy | Read receipts: public / private (D7); typing notices on/off; media previews; URL previews |
| Appearance | System / light / dark, text size follows Dynamic Type, timeline density |
| Stickers | Manage packs (built: list + remove enabled packs), favourites (links to the sticker manager; not built) |
| Bots | Allowlisted bot user IDs for template cards (synced as `one.mbm.halo.bot_allowlist`, see BOT_MESSAGES §3) |
| Storage | SDK store sizes, clear media cache (built: clears in-memory thumbnails and per-session `caches/` directories) |
| Diagnostics | Auditor summary (debug/TestFlight), "Reconcile now", "Export diagnostics (.zip)" (`DiagnosticsZipArchive`, built) |
| Privacy (app switcher) | "Hide content in app switcher" (D61, built) |
| Focus | "Follow Focus filters" (D104, built, default **off**): only while on does a Focus's Halo filter (D90) narrow the chat list |
| Setup | First-run checklist (SCREEN_SPECIFICATIONS S15) while a step is left (not built, ROADMAP M13) |
| Feedback | "Send feedback": mail/share sheet with an optional diagnostics `.zip` the user chooses to attach (not built, ROADMAP M15) |
| About | Version, SDK version, **Acknowledgements** (generated, D39), licence notice, privacy policy and support links, "What's New" (not built, ROADMAP M15) |

## 4. Non-functional requirements
Every setting persisted immediately; server-backed settings show their sync state.

## 5–6. Flows and states
Standard navigation list; toggles apply immediately (with rollback on server failure).

## 7. Data models
`AppPreferences` (UserDefaults, App Group); server-backed: push rules, account data.

## 8. API boundaries
`AccountDataPort`, `ProfilePort`, `EncryptionPort`, `PusherPort`, platform ports.

## 9. Error scenarios
A server-backed toggle fails → revert and toast.

## 10. Edge cases
Notification permission revoked in iOS Settings → status shows "Off" with a link.

## 11. Acceptance criteria
- AC-SET-1 The acknowledgements list matches the generated inventory for the build.
- AC-SET-2 Switching to private receipts makes later receipts `m.read.private` (verified on the server).

## 12. Test requirements
Unit: preference persistence; integration S-SET-1 (private receipts).

## 13. Open questions
—
