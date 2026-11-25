# Security

## 1. Threat model (summary)

| Asset | Threats | Main controls |
|---|---|---|
| Message content (E2EE) | Server operator, network attacker, device thief, logs/backups leaking | Megolm/Olm via the SDK; device verification; file protection; no content in logs; iCloud backup exclusion of caches |
| Crypto keys and sessions | Theft from the device, the Keychain or backups | SDK crypto store encrypted with a passphrase from the Keychain (`afterFirstUnlockThisDeviceOnly`, not synced) |
| Access tokens | Theft → account takeover | Keychain only; never logged; OIDC refresh rotation |
| Metadata (who, when) | Server operator, push gateway, Apple | Minimise: `event_id_only` pushes; no third-party analytics |
| App integrity | Supply chain (dependencies, prebuilt binaries) | Pinned versions + checksums; licence/source gate; build from source before external distribution |

## 2. End-to-end encryption considerations
- All crypto runs in matrix-rust-sdk (vodozemac). Halo never handles key material directly.
- New rooms created by Halo are encrypted by default (DMs and private rooms) **[DECISION D60]**.
- Unverified devices: show an "unverified" state; sending into rooms with unverified devices follows the SDK's default room-key recipient strategy (configurable via `ClientBuilder.room_key_recipient_strategy` **[VERIFIED F-FFI-18]**; the SDK default is kept, D117).
- Identity changes of contacts are shown in the timeline (ENCRYPTION_AND_DEVICES FR-7). **Not built** (2026-11-25): a changed identity is silent today (ROADMAP M18-1, AC-SEC-1).
- **Unencrypted surfaces** users must know about: image packs/stickers (F-SPEC-3), room names/topics/avatars (state), push metadata (room/event ids to Sygnal and Apple).

## 3. Key and session storage
| Secret | Where | Accessibility | Shared with NSE |
|---|---|---|---|
| Session (tokens, device id) | Keychain `session.v1` | `afterFirstUnlockThisDeviceOnly` | Yes (access group) |
| SDK store passphrase | Keychain `sdk-store-passphrase.v1` (32 random bytes) | same | Yes |
| Halo field-encryption key | Keychain `halo-db-key.v1` | same | Yes |
| Recovery key | **Never stored** by Halo; shown once on setup for the user to save | — | — |

`kSecAttrSynchronizable = false` for all items (no iCloud Keychain sync).

## 4. Secure local persistence
File protection `completeUntilFirstUserAuthentication` for all Halo/SDK files; caches excluded from iCloud backups
(`isExcludedFromBackup`; **set only for the MetricKit payloads yet**, ROADMAP M18-4); field encryption in `halo.sqlite` ([../data/PERSISTENCE.md](../data/PERSISTENCE.md) §3).
Screenshots in the app switcher: a privacy blur when backgrounding (setting, default on) **[DECISION D61]**. It covers the screen only while the app is leaving (active → inactive → background), so the snapshot is blurred, and is lifted as soon as the app comes back; it is never shown during a cold launch and carries no icon (D105).

## 5. Network security
- TLS via the SDK (rustls with aws-lc-rs, F-FFI-1); system trust store plus the SDK's built-in roots.
- **Never** call `disable_ssl_verification` (exists in the builder, F-FFI-18) outside a debug-only local-CA setup; a build check fails release builds that reference it (the check doesn't exist yet, ROADMAP M18-12).
- ATS stays enabled with no exceptions; the Sygnal and homeserver endpoints use HTTPS.
- Halo makes direct HTTP calls only for documented exceptions (sticker state fetch, option B in STICKERS §9; KLIPY GIF/sticker search and media, COMPOSER_PANELS §6 / D98, without any Matrix token), through the same TLS settings, with the access token in the `Authorization` header only where one is sent.

## 6. Logging restrictions (hard rules)
| Never log | Instead |
|---|---|
| Message bodies, formatted bodies, sticker bodies, file names | Event type + length |
| Access/refresh tokens, passphrases, recovery keys, Keychain values | Nothing |
| Full Matrix IDs (users, rooms, events) | `HaloLog.id(x)` → short salted hash (salt per install) |
| Media URLs (`mxc://`) | Hash |
| Push tokens | Last 4 characters |
Lint: a SwiftLint custom rule flags `print(` and string interpolation of known sensitive types into `Logger` without `privacy: .private` (not in `.swiftlint.yml` yet, ROADMAP M18-12).

## 7. Private repository practices
- The repository is private (D2); branch protection on `main` (when collaborators join).
- No secrets in the repo: APNs keys, signing certificates, Sygnal config secrets, MAS client secrets live in the password manager / CI secrets; `infra/` uses `.env.example` files only.
- Secret scanning: `gitleaks` in CI (planned for M0) and a pre-commit hook.
- Signing: automatic signing locally; certificates never committed.

## 8. Dependency security
See [LICENSE_COMPLIANCE.md](LICENSE_COMPLIANCE.md) and [DEPENDENCY_INVENTORY.md](DEPENDENCY_INVENTORY.md). Additionally: the SDK is pinned by exact version + checksum; bumps are reviewed (changelog + security advisories, e.g. vodozemac/matrix-sdk-crypto advisories) before merge.

## 9. Vulnerability response
A `SECURITY.md` contact isn't needed while the app is private; before public release (ROADMAP M18-12), add a disclosure policy and track SDK security advisories (GitHub advisories for matrix-org/matrix-rust-sdk).
