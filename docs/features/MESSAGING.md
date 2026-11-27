# Feature: Messaging (Composer, Sending, Interactions)

> Priority: P1 · Milestone: M2 · Modules: FeatureComposer, FeatureTimeline, `TimelinePort` · Requirements: R-P1-MSG

## 1. Purpose
Send, reply, edit, delete and react reliably, online or offline.

## 2. User stories
- I type with Markdown, mention people, and send; the message appears immediately and shows when it's sent.
- I reply, edit and delete my messages; I react with emoji.
- Offline, my messages wait and go out automatically later.
- I see who is typing.

## 3. Functional requirements
- FR-1 Composer: multiline text, Markdown → HTML (`formatted_body`), mentions picker (`@` → members) producing pills and `m.mentions`. A display name is set by its owner, so in the link text every ASCII punctuation character is backslash-escaped (no HTML, emphasis or nested link from a name) and the user ID is percent-encoded outside the user-ID grammar.
- FR-2 Send via `Timeline.send` / `send_reply` / `edit` / `redact_event` / `toggle_reaction` **[VERIFIED F-FFI-8]**.
- FR-3 Send queue enabled (`enable_all_send_queues`); local echo states: sending → sent → failed (retry / delete via `retry_send` / `abort_send`).
- FR-4 Typing notices: `typing_notice(true)` while typing (throttled 4 s), false on send/clear; show typing users from `subscribe_to_typing_notifications` **[VERIFIED F-FFI-6]**.
- FR-5 Drafts per room kept locally (P2: synced via `ComposerDraft` API).
- FR-6 After sending → read intent at the own event (E1b).
- FR-7 Emoji reactions: quick bar (6 recents) + full picker; custom emoticons from image packs (P2).
- FR-8 Forward text, media, files, stickers and locations to one or more chats, re-encrypted for the target; warns when the target isn't encrypted and the source is. **Built** (M20-6): `ForwardPayload`/`ForwardTarget`/`ForwardPolicy`/`ForwardOutcome` in `HaloDomain`, `ForwardCoordinator` in `HaloApplication` (downloads/decrypts source media once, streams videos/audio/files to disk, sends freshly through each target `TimelineSession` so encrypted destinations get new keys/IVs per AC-M4), searchable multi-target `ForwardSheet` with encryption badges, explicit confirmation alert when leaving an encrypted room, and partial-failure retry for failed destinations. Verified by `ForwardingTests`, `ForwardCoordinatorTests`, `ForwardSheetTests`, Light/Dark/AX5 snapshots, and live Synapse `InteropTests.forwardEncryptedPhotoAndTypes`.
- FR-9 A failed send carries the SDK's reason (`QueueWedgeError`, F-FFI-24): network, refused by the server, or an encryption refusal naming the people or devices **Built** (M18-2): `TimelineEvent.sendFailure` (`SendFailure`) says unverified devices, changed identity, device not verified, session expired, file gone, or other; the status line names the people, and "Send anyway" (SDK `ignoreDeviceTrustAndResend` / `withdrawVerificationAndResend`) is offered only for the first two. Nothing is ever sent unencrypted instead. The SDK default recipient strategy (D117) seldom refuses, so no real-server test makes it refuse; each reason is covered by a mapping test.
- FR-10 Polls: vote, change the vote, end an own poll, and see live disclosed results (or hidden counts for undisclosed polls until ended). **Built** (M20-4): `PollDetails` / `PollOption` / `PollVisibility` in `HaloDomain`, `TimelineSession.votePoll` & `endPoll` via SDK `sendPollResponse` / `endPoll`, and interactive `PollCardView` with pending-vote indicator until server confirmation (AC-M5), single-choice and multi-select support, error feedback on failure/offline, and confirmation before ending own polls. Verified by `PollDetailsTests`, `PollInteractionTests`, and two-account `InteropTests.pollsTwoAccounts`.
- FR-11 Multi-select for copy, forward and delete (candidate, D122, ROADMAP M20-16).

## 4. Non-functional requirements
Local echo appears in < 100 ms; no message lost across app kill (V-SYNC-2).

## 5. User flows
Type → send → local echo → server echo replaces it. Long-press → reply / edit / delete / react / copy / view source.

## 6. State transitions
`Draft → Sending → Sent`; `Sending → Failed(retryable) → Sending`; `Failed(nonRetryable) → Deleted`.

## 7. Data models
`MessageDraft { text, mentions, replyTo? }`, `SendState`.

## 8. API boundaries
`TimelinePort` session methods; `RoomPort.members` for mentions.

## 9. Error scenarios
Rate limited (auto-retry after `retry_after`) · unknown/unverified devices in an E2EE room (`withdraw_verification_and_resend`, `ignore_device_trust_and_resend` exist — UI prompt *not built*, FR-9) · forbidden (power levels).

## 10. Edge cases
Editing while the original is still sending · deleting a failed local echo · a reaction toggled twice quickly · a very long message · pasted rich text.

## 11. Acceptance criteria
- AC-M1 Text/reply/edit/reaction/delete show as a local echo immediately and survive an app kill (sent on relaunch).
- AC-M2 Mentions produce `m.mentions` and pills that render in Element Web.
- AC-M3 Typing indicator appears within 2 s on the other side.
- AC-M4 A forwarded encrypted photo opens for the new recipients and isn't readable by the server.
- AC-M5 A vote shows as pending until the server has it; changing it leaves one vote per person.
- AC-M6 A send refused because an identity changed names the person, and sending works after the user accepts.

## 12. Test requirements
Unit: composer formatting (Markdown → HTML subset), mention extraction, typing throttle. Integration: S-MSG-1..5. UI: send + reply smoke.

## 13. Open questions
—
