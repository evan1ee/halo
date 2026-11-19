# Glossary

| Term | Definition |
|---|---|
| **Adapter** | `HaloMatrixAdapter`, the only Swift module that imports upstream `MatrixRustSDK` types; it implements the ports |
| **Attention** | A room "needs attention" when it should count towards the app badge (see [matrix/UNREAD_STATE.md](matrix/UNREAD_STATE.md) §5) |
| **Badge** | The app icon number = count of rooms needing attention (D5) |
| **Confidence** | How sure the read-state policy is about a room's count: `exact`, `approximate`, `unknown` |
| **Fully-read marker** | `m.fully_read` room account data: where the user has caught up to; drives the "new messages" line, not counts |
| **Gate** | A named validation checkpoint (e.g. G-FFI, G-UNREAD) that must pass before the plan continues |
| **Highlight** | A notification that is a mention or keyword match (`highlight_count`, `num_unread_mentions`) |
| **Local read intent** | A read position the user reached on this device that the server hasn't confirmed yet (receipt outbox) |
| **MAS** | Matrix Authentication Service, the OIDC provider for Synapse |
| **NSE** | Notification Service Extension: an iOS extension process that changes push content before it's shown |
| **Port** | A Halo-owned Swift protocol in `HaloDomain` describing what the app needs from Matrix (e.g. `RoomReadStatePort`) |
| **Read receipt** | An `m.read` / `m.read.private` receipt: "read up to event E", shared across devices; public receipts are visible to others |
| **Room snapshot** | An immutable value describing a room at a sync position, produced by the adapter |
| **Server counts** | `notification_count` / `highlight_count` computed by the homeserver from push rules after the user's latest receipt |
| **SDK counts** | `num_unread_messages` / `num_unread_notifications` / `num_unread_mentions` computed on the device by matrix-rust-sdk |
| **Sliding sync** | Simplified Sliding Sync (MSC4186), the sync protocol used by `SyncService` |
| **Sygnal** | Matrix push gateway (Apache-2.0) that forwards homeserver pushes to APNs |
| **UTD** | "Unable to decrypt": an encrypted event whose keys aren't (yet) available |
