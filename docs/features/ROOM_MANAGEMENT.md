# Feature: Room Management

> Priority: P1 · Milestone: M2 (details, leave, modes), M5 (create, invite) · Modules: FeatureRoomDetails, `RoomPort` · Requirements: R-P1-ROOM

## 1. Purpose
See and manage a room's details, members and notification behaviour; start new conversations.

## 2. User stories
- I see a room's name, avatar, topic, encryption status and members.
- I change notification mode, mark it favourite, leave it.
- I start a DM with someone or create a private room and invite people.
- I accept or decline invitations.

## 3. Functional requirements
- FR-1 Details from `RoomInfo` (name, topic, avatar, encryption, member counts) **[VERIFIED F-FFI-7 fields exist]**.
- FR-2 Members list (paged, iterator `RoomMembersIterator` **[VERIFIED F-FFI-18]**), with power-level badges.
- FR-3 Notification mode: all / mentions & keywords / mute (FR-8 of NOTIFICATIONS).
- FR-4 Leave room (confirm; warn if the user is the last admin).
- FR-5 Create DM (`create_room` with `is_direct`, or `get_dm_room` if it exists **[VERIFIED F-FFI-18]**), create private encrypted room, invite users (`search_users`).
- FR-6 Invites: accept (`join_room_by_id`), decline (leave), preview (`get_room_preview_from_room_id`).
- FR-7 Edit name/topic/avatar if allowed by power levels (`get_power_levels`).
- FR-8 Mark as unread / read (READ_RECEIPTS explicit actions).
- FR-9 Report a message or room to the homeserver, with ignore offered in the same place (`report_content`, `report_room`, F-FFI-24). *Not built; App Review 1.2 needs it* (ROADMAP M20-7, Q-REPORT).
- FR-10 Remove, ban and unban members, gated by live power levels (`RoomPowerLevel`, `RoomModerationPermissions`, `RoomModerationPolicy` in `HaloDomain`; `MatrixRoomPort` reads live `RoomPowerLevels` + member `PowerLevel` incl. room v12 `.infinite` creator and executes `kickUser` / `banUser` / `unbanUser` / `bannedMembers`; `RoomDetailsView` shows `Creator` / `Admin` / `Moderator` role badges, per-member moderation menu/swipe/context actions with optional reason confirmation, a `Banned` section with `Unban`, and explains server `.forbidden` / offline refusals without mutating state — **built** 2026-11-28, ROADMAP M20-12). Role editor, join rules, history visibility and aliases are post-launch (D122).
- FR-11 Upgraded rooms link to their successor (`m.room.tombstone`, `RoomInfo.successorRoom`) in the timeline banner and Room Details (with Leave & Forget); knock-only, invite-only, restricted, banned, and left rooms explain their state with honest previews (`RoomPreviewSheet`), knock request / cancel, and a Left & Pending Rooms view (`InactiveRoomsView`) so no room row is stuck (ROADMAP M20-8).

## 4. Non-functional requirements
Member lists of 10k members page smoothly.

## 5–6. Flows and states
Room → info sheet → actions; invite: `Invited → Joining → Joined | Failed`.

## 7. Data models
`RoomDetails`, `RoomMember { userId, displayName, avatar, powerLevel, membership }`.

## 8. API boundaries
`RoomPort`, `ProfilePort`.

## 9. Error scenarios
No permission (`forbidden`) · server ACLs · invite to a non-existent user.

## 10. Edge cases
Rooms with no name (compute from heroes) · tombstoned rooms · public rooms joined by alias (`join_room_by_id_or_alias`).

## 11. Acceptance criteria
- AC-ROOM-1 Mode changes are reflected in push rules (visible in Element Web).
- AC-ROOM-2 A created DM is recognised as a DM in Element Web.
- AC-ROOM-3 A report reaches the homeserver's admin API and the app says who receives it.
- AC-ROOM-4 Actions the power levels don't allow aren't offered; one refused by the server is explained and nothing changes.

## 12. Test requirements
Unit: view models with a fake port. Integration: S-ROOM-1..3.

## 13. Open questions
Q-REPORT.
