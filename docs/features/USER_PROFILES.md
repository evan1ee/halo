# Feature: User Profiles

> Priority: P1 · Milestone: M2 · Modules: FeatureProfile, `ProfilePort` · Requirements: R-P1-PROF

## 1. Purpose
Manage your own profile; see and act on other people's.

## 2. User stories
- I change my display name and avatar.
- I tap a person to see their profile, start a DM, verify them, or ignore them.

## 3. Functional requirements
- FR-1 Own profile: `display_name`, `set_display_name`, `avatar_url`, `upload_avatar`, `remove_avatar`, `subscribe_to_own_profile` **[VERIFIED F-FFI-4 names]**.
- FR-2 Other profiles: `get_profile(userId)`; room-specific display names from membership.
- FR-3 Actions: message (DM), ignore/unignore (the server's `m.ignored_user_list`, D120), report (ROADMAP M20-7), verify identity (post-launch, Q-VERIFY), copy user ID / share link (`matrix.to`).
- FR-4 Ignored users list in Settings (`ignored_users`).

## 4. Non-functional requirements
Avatar upload ≤ 1 MB after resizing to 512 px.

## 5–6. Flows and states
Profile sheet; avatar change: pick → crop → upload → confirm.

## 7. Data models
`UserProfile { userId, displayName, avatar }`.

## 8. API boundaries
`ProfilePort`.

## 9. Error scenarios
Upload failed · profile not found (federated server down).

## 10. Edge cases
Display names with RTL characters or impersonation (show the user ID under the name) · users without a display name.

## 11. Acceptance criteria
- AC-PROF-1 A display-name change appears in Element Web.
- AC-PROF-2 Ignoring a user hides their messages after the next sync.

## 12. Test requirements
Unit + integration S-PROF-1..2.

## 13. Open questions
—
