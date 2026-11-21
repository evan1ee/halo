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
| Account | Profile, sessions/devices, sign out |
| Security | Verification status, recovery key setup/change, key backup state |
| Notifications | Permission status, push health, defaults for DMs/groups (built: all messages / mentions and keywords), name and @room mention toggles (built), keyword rules (not built) |
| Privacy | Read receipts: public / private (D7); typing notices on/off; media previews; URL previews |
| Appearance | System / light / dark, text size follows Dynamic Type, timeline density |
| Stickers | Manage packs (built: list + remove enabled packs), favourites (links to the sticker manager; not built) |
| Bots | Allowlisted bot user IDs for template cards (synced as `one.mbm.halo.bot_allowlist`, see BOT_MESSAGES §3) |
| Storage | SDK store sizes, clear cache |
| Diagnostics | Auditor summary (debug/TestFlight), "Reconcile now", "Export diagnostics", log level |
| About | Version, SDK version, **Acknowledgements** (generated, D39), licence notice |

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
