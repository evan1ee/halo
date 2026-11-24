# Halo Support

*Publish at `[https://YOUR_DOMAIN/support]` before Beta 2 / App Store submission.*

## Getting Started
1. **Sign in:** Enter your Matrix homeserver domain (for example `matrix.org` or your self-hosted server). Halo supports both OIDC (Matrix Authentication Service) and native password sign-in.
2. **Verify your device:** After signing in, open **Settings → Encryption & Security** to enter your Recovery Key or verify from another signed-in device so encrypted history decrypts seamlessly.
3. **Notifications:** Enable notifications when prompted so Halo can fetch and decrypt incoming messages locally on your device.

## Common Questions
- **Why did I see "Unable to decrypt"?** Verify your device or restore your Recovery Key under **Settings → Encryption & Security**.
- **How do custom sticker packs work?** Open **Settings → Stickers** to view, create, rename, or edit MSC2545 sticker packs, or long-press any photo in a chat and choose **Add to Stickers**.
- **How do I pin a message?** Long-press any message and tap **Pin**. Room moderators pin for everyone (`m.room.pinned_events`); regular members get Matrix-synced personal pins (`one.mbm.halo.pinned_events`). Swipe left or right on the top pin pill to cycle through pinned messages, or tap it to view all pins.
- **How do I report a bug?** Go to **Settings → Send feedback** to export an optional, redacted diagnostics archive (no message content or raw Matrix IDs) and share it with us.

## Contact
Need help? Reach out at `[support@YOUR_DOMAIN]` or `[https://YOUR_DOMAIN/issues]`.
