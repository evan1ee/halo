# Privacy

## 1. Principles
No third-party analytics, ads or tracking SDKs. Data leaves the device only to the user's homeserver (Matrix), the push
gateway and Apple (APNs metadata), and through explicit user actions (export, share).

## 2. Data flows and boundaries

| Data | Goes to | Why | Visible to |
|---|---|---|---|
| Messages, media (E2EE rooms) | Homeserver (encrypted) | Messaging | Room members' devices |
| Messages, media (unencrypted rooms) | Homeserver | Messaging | Server operators, room members |
| Read receipts | Homeserver | Read state | Room members (public) or only own devices (private, D7) |
| Typing notices | Homeserver | UX | Room members (toggle in Settings) |
| Image packs + their media | Homeserver (unencrypted) | Stickers | Server operators, pack room members |
| Push: room id, event id, counts | Synapse → Sygnal → APNs | Notifications | Push gateway operator, Apple |
| Account data (`app.halo.*`) | Homeserver (unencrypted) | Sync of favourites, allowlist | Server operator **[DECISION: accepted for stickers prefs; revisit for anything sensitive]** |
| Diagnostics export | Only where the user shares it | Debugging | Recipient |
| Bot conversations | The bot's room (normal Matrix) | Bot features | The bot backend (by the user's choice to talk to it) |

## 3. Bot privacy (D18)
Halo never sends data to a bot or AI service on its own. Rendering and indexing of bot messages happen on the device, from
messages already in the user's rooms. Any future feature that sends content to a bot must be an explicit user action and be documented here first.

## 4. Local data
Covered in [SECURITY.md](SECURITY.md) §3–4. The Bot Activity index and audit log stay on the device.

## 5. App Store privacy (before public release)
Privacy nutrition labels: "Data not collected" for analytics; "Data linked to you" only as needed for the account at the user's own homeserver (to be reviewed with the legal review, D38).
