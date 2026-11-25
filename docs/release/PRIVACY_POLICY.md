# Halo Privacy Policy

*Last updated: 2026-11-24 — Publish at `[https://YOUR_DOMAIN/privacy]` before Beta 2 / App Store submission. Draft: publish only text that matches the build (ROADMAP M22-3; MetricKit isn't in the app yet, M17-2).*

Halo is an independent iOS and iPadOS client for the Matrix messaging protocol. Privacy is a core design principle: Halo contains **no third-party analytics, advertising, tracking, or crash-reporting SDKs**.

## 1. Data Halo Does Not Collect
- Halo's developer does **not** operate a central analytics server and does **not** collect your messages, contacts, Matrix ID, room list, or usage telemetry.
- Crash diagnostics use Apple's built-in opt-in Crash Organizer and on-device MetricKit only (D114).

## 2. Where Your Data Goes
Data leaves your device only when required for the features you use:
- **Your Matrix homeserver:** Messages, media, reactions, read receipts, typing notices (optional), and Halo preference account data (`one.mbm.halo.*`) are sent to the Matrix homeserver you sign in to. In end-to-end encrypted (E2EE) rooms, message content and media are encrypted on your device before upload.
- **Push notifications (Sygnal & Apple APNs):** When notifications are enabled, your homeserver sends push metadata (room ID and event ID) via the push gateway to Apple Push Notification service (APNs). Halo fetches and decrypts the event on your device inside the Notification Service Extension.
- **KLIPY GIF & sticker search (optional):** When you open the GIFs tab or search KLIPY, your search query, region, and a random per-install identifier (never your Matrix ID or message text) are sent to KLIPY (`api.klipy.com`). Received KLIPY links load only when media previews are enabled.
- **Location & voice messages (explicit user action only):** Location coordinates (`m.location`) and voice recordings (`m.audio`) are accessed and sent only when you explicitly choose to send them, and are encrypted in E2EE rooms.
- **Diagnostics export (explicit user action only):** Logs and unread-state diagnostics never leave your device unless you explicitly choose **Settings → Send feedback** and share the archive yourself.

## 3. On-Device Storage & Security
- Session credentials and database encryption keys are stored in the iOS Keychain (`afterFirstUnlockThisDeviceOnly`, non-synchronizable).
- Local drafts and bot-task titles in `halo.sqlite` are encrypted at rest with AES-256-GCM using a per-account Keychain key, in addition to iOS file protection (`completeUntilFirstUserAuthentication`).
- **Siri, Spotlight & Widgets (opt-in):** Off by default. If you enable **Chats in Siri and Spotlight**, up to 100 chat names and room IDs (no message text or avatars) are indexed locally for Siri, Spotlight, and the Unread Chats widget. Turning the setting off or signing out deletes them immediately.

## 4. Contact
For privacy questions or requests, contact: `[privacy@YOUR_DOMAIN]`.
