# Feature: End-to-End Encryption and Devices

> Priority: P1 · Milestone: M1 · Modules: FeatureSettings, FeatureAuth (onboarding step), adapter `EncryptionPort` · Requirements: R-P1-E2EE

## 1. Purpose
Read and send encrypted messages from a verified device and recover history on a new device.

## 2. User stories
- After signing in I verify this device with my other device (QR code or emoji) or with my recovery key.
- I can see why a message can't be decrypted.
- I can list and sign out my other sessions.

## 3. Functional requirements
- FR-1 Cross-signing bootstrap via `ClientBuilder.auto_enable_cross_signing(true)` and key backup via `auto_enable_backups(true)` **[VERIFIED F-FFI-18]**.
- FR-2 Verification flows through `get_session_verification_controller` (emoji/SAS) and the QR login/verify handlers **[VERIFIED F-FFI-18; flow details at M1]**.
- FR-3 Recovery: enter the recovery key → restore secrets and the backup (`client.encryption()` API **[VERIFIED V-E2EE-1]**; in code (M1): `EncryptionPort`/`EncryptionCoordinator`, the "Verify this device" banner and recovery-key sheet in FeatureAuth. QR/emoji verification (FR-2), UTD reasons (FR-5) and device list (FR-6) are still to do.).
- FR-4 Show the verification state (verified / unverified / no recovery set up) in Settings, with a banner until verified.
- FR-5 UTD placeholder with a reason from the timeline item (unknown keys, unverified sender, withheld) and an automatic retry when keys arrive (`retry_decryption`) **[VERIFIED F-FFI-8]**.
- FR-6 Session list: MAS account management URL (`account_url`) for OIDC accounts; native list for password accounts **[OPEN Q-MAS-ACCOUNT]**.
- FR-7 Identity changes of contacts (`subscribe_to_identity_status_changes`) shown as a timeline notice.

## 4. Non-functional requirements
Crypto material never leaves the SDK stores; the store passphrase is generated (32 random bytes, base64) and kept in the Keychain.

## 5. User flows
Sign in → "Verify this device" (choose: other device / recovery key / skip) → done → backup restore runs in the background with progress.

## 6. State transitions
`Unverified → Verifying → Verified`; `Unverified → RecoveryKeyEntered → Verified`; `Verified → IdentityReset` (from another device).

## 7. Data models
`VerificationState`, `BackupState { enabled, progress }`, `UTDReason`.

## 8. API boundaries
`EncryptionPort` only; the feature never touches keys.

## 9. Error scenarios
Wrong recovery key · the other device cancels · verification timeout · backup missing.

## 10. Edge cases
The user skips verification → banner remains; sends still work (sender unverified) · identity reset on another device · very large backups (progress, resumable).

## 11. Acceptance criteria
- AC-E2EE-1 After QR or emoji verification, historic encrypted messages decrypt.
- AC-E2EE-2 With the recovery key alone (no other device), history decrypts.
- AC-E2EE-3 A UTD message turns into the decrypted message without user action once keys arrive.

## 12. Test requirements
Integration: verification between two headless clients is hard to automate → manual test plan M1; recovery key restore
automated against the dev Synapse (S-E2EE-1). Unit: view-model state machines with a fake port.

## 13. Open questions
V-E2EE-1, Q-MAS-ACCOUNT.
