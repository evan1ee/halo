# Halo — App Store Metadata & Release Checklist

Draft metadata for App Store Connect (`Q-APPSTORE`, D115). Replace bracketed `[...]` placeholders with your published domain and contact details before submission.

## 1. App Information
- **Name:** Halo
- **Subtitle (≤ 30 chars):** Fast, reliable Matrix chat
- **Primary Category:** Social Networking
- **Secondary Category:** Utilities *(optional)*
- **Bundle ID:** `one.mbm.halo` (D63)
- **Primary Language (Beta 1):** English (`en`, D111)
- **Support URL:** `[https://YOUR_DOMAIN/support]` (source: [SUPPORT.md](SUPPORT.md))
- **Privacy Policy URL:** `[https://YOUR_DOMAIN/privacy]` (source: [PRIVACY_POLICY.md](PRIVACY_POLICY.md))

## 2. Store Copy
- **Promotional Text (≤ 170 chars):**
  > End-to-end encrypted Matrix messaging for iPhone and iPad — built natively for iOS 26 with rock-solid unread counts, custom sticker packs, and zero tracking.
- **Description:**
  > Halo is an independent, native iOS client for the open Matrix protocol, built from the ground up with SwiftUI and the official Matrix Rust SDK.
  >
  > **Highlights**
  > - **Honest unread counts & notifications:** Unread indicators, read receipts, and the app icon badge are computed locally from synchronized Matrix state — never overwritten by stale server badge counts.
  > - **End-to-end encryption:** Cross-signing verification (SAS emoji/decimal) and Recovery Key backup/restore out of the box.
  > - **Rich messaging:** Replies, threads, edits, reactions, mentions, pinned messages, voice messages, polls, location cards, Markdown articles, and full-screen photo viewer with Live Text.
  > - **Custom sticker packs:** Browse, search, favorite, and manage MSC2545 image packs — or save any photo directly into your own sticker pack.
  > - **Apple-native experience:** Liquid Glass navigation, Dynamic Type & VoiceOver support, iPad split view with hardware keyboard shortcuts and drag-and-drop, Home Screen & Lock Screen widgets, Focus filters, and optional Siri & Spotlight integration.
  > - **Private by design:** Zero third-party analytics, ads, or crash-reporting SDKs. Your messages go only to your chosen Matrix homeserver.
- **Keywords (≤ 100 chars):**
  > matrix,chat,messaging,encrypted,e2ee,stickers,privacy,messenger,synapse,federated

## 3. Age Rating & Export Compliance
- **Age Rating:** Complete Apple's User-Generated Content questionnaire (Matrix is a federated messaging protocol; users choose their own homeserver and rooms; Halo includes user-ignore / room-leave controls).
- **Export Compliance (`V-LEGAL`):** Uses standard HTTPS/TLS and Matrix E2EE (`matrix-rust-sdk` Olm/Megolm) + iOS `CryptoKit` AES-256-GCM for local field encryption. Complete Apple's encryption compliance questionnaire and legal review (D38) before external TestFlight.

## 4. Privacy Nutrition Labels (grounded in [../security/PRIVACY.md](../security/PRIVACY.md))
- **Tracking:** None (`NSPrivacyTracking = false` in all `PrivacyInfo.xcprivacy` manifests).
- **Analytics / Advertising:** Data Not Collected.
- **Data Linked to You:** Only what the user voluntarily transmits to their chosen Matrix homeserver (User ID, messages, media, optional location/voice messages when explicitly sent).
- **App Review Note (dormant Sentry crates, `PRIVACY.md` §2b):**
  > Halo consumes the upstream prebuilt `MatrixRustSDK` binary (`26.11.17`, D113), which links dormant `sentry` crates. Halo passes `sentry_config = nil` at startup and never initializes or transmits data to Sentry.

## 5. Screenshot Matrix (M15)
Generate in Light & Dark modes on **6.9"** and **6.3"** iPhone displays (and 13" iPad if publishing iPad screenshots):
1. Chats list with unread badges and clean Liquid Glass header
2. Conversation timeline with photos, reactions, and pinned message pill
3. Custom sticker library & expression panel
4. Full-screen photo viewer / Global Media Gallery
5. Settings & E2EE verification status
