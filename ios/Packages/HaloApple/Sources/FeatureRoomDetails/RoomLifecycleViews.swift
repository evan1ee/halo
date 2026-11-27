#if canImport(SwiftUI)
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import Observation
import SwiftUI

/// Drives `RoomPreviewSheet` for any room address (public, knock, knocked, invite-only, banned, left, invited, joined; M20-8).
@MainActor @Observable
public final class RoomPreviewViewModel: Identifiable {
    public enum Phase: Equatable {
        case loading
        case loaded(RoomLifecyclePreview)
        case failed(String)
    }

    public let id = UUID()
    public let address: String
    public let focusEvent: EventID?
    public private(set) var phase: Phase = .loading
    public var knockReason = ""
    public private(set) var isActing = false
    public private(set) var actionError: String?
    public private(set) var openedRoom: RoomID?
    public private(set) var completedDismiss = false

    @ObservationIgnored private let rooms: any RoomPort
    @ObservationIgnored private let chats: any ChatCreationPort
    @ObservationIgnored private let actions = ActionGuard()

    public init(
        address: String,
        focusEvent: EventID? = nil,
        rooms: any RoomPort,
        chats: any ChatCreationPort
    ) {
        self.address = address
        self.focusEvent = focusEvent
        self.rooms = rooms
        self.chats = chats
    }

    public func load() async {
        phase = .loading
        actionError = nil
        do throws(HaloError) {
            let preview = try await rooms.previewRoom(address: address)
            phase = .loaded(preview)
        } catch {
            phase = .failed(Self.errorText(error, verb: "load this room"))
        }
    }

    public func join() async {
        await runAction(verb: "join this room") {
            let target = self.currentPreview?.roomID?.rawValue ?? self.address
            let id = try await self.chats.joinRoom(target)
            self.openedRoom = id
        }
    }

    public func acceptInvite(_ roomID: RoomID) async {
        await runAction(verb: "accept this invitation") {
            try await self.rooms.acceptInvite(roomID)
            self.openedRoom = roomID
        }
    }

    public func declineInvite(_ roomID: RoomID) async {
        await runAction(verb: "decline this invitation") {
            try await self.rooms.declineInvite(roomID)
            self.completedDismiss = true
        }
    }

    public func knock() async {
        await runAction(verb: "send a join request") {
            let target = self.currentPreview?.roomID?.rawValue ?? self.address
            let id = try await self.rooms.knock(address: target, reason: self.knockReason)
            if let current = self.currentPreview {
                self.phase = .loaded(RoomLifecyclePreview(
                    roomID: id, address: current.address, name: current.name, topic: current.topic,
                    avatar: current.avatar, memberCount: current.memberCount, membership: .knocked, joinAccess: current.joinAccess
                ))
            } else {
                await self.load()
            }
        }
    }

    public func cancelKnock(_ roomID: RoomID?) async {
        guard let roomID else { completedDismiss = true; return }
        await runAction(verb: "cancel your request") {
            try await self.rooms.leave(roomID)
            try? await self.rooms.forget(roomID)  // best-effort: some servers auto-forget cancelled knocks
            self.completedDismiss = true
        }
    }

    public func forget(_ roomID: RoomID?) async {
        guard let roomID else { completedDismiss = true; return }
        await runAction(verb: "forget this room") {
            try await self.rooms.forget(roomID)
            self.completedDismiss = true
        }
    }

    public func openExisting(_ roomID: RoomID) {
        openedRoom = roomID
    }

    private var currentPreview: RoomLifecyclePreview? {
        if case .loaded(let preview) = phase { return preview }
        return nil
    }

    private func runAction(verb: String, _ work: @escaping @MainActor () async throws -> Void) async {
        await actions.run("room-preview-action") {
            isActing = true
            actionError = nil
            defer { isActing = false }
            do {
                try await work()
            } catch let error as HaloError {
                actionError = Self.errorText(error, verb: verb)
            } catch {
                actionError = "Couldn't \(verb). Try again."
            }
        }
    }

    private static func errorText(_ error: HaloError, verb: String) -> String {
        switch error {
        case .notFound: "That room wasn't found."
        case .forbidden: "You don't have permission to \(verb). The room may be invite-only or you may be banned."
        case .network: "You appear to be offline, so Halo couldn't \(verb). Try again."
        case .unauthorized: "Sign in again to \(verb)."
        default: "Couldn't \(verb). Try again."
        }
    }
}

/// Sheet showing the honest preview and allowed action for any room lifecycle state (ROADMAP M20-8, ROOM_MANAGEMENT FR-11).
public struct RoomPreviewSheet: View {
    @State private var model: RoomPreviewViewModel
    private let onOpenRoom: @MainActor (RoomID, EventID?) -> Void
    private let onDismiss: @MainActor () -> Void

    public init(
        model: RoomPreviewViewModel,
        onOpenRoom: @escaping @MainActor (RoomID, EventID?) -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        _model = State(initialValue: model)
        self.onOpenRoom = onOpenRoom
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    LoadingState()
                case .failed(let message):
                    ErrorState(title: "Couldn't load room", message: message) {
                        Task { await model.load() }
                    }
                case .loaded(let preview):
                    ScrollView {
                        RoomPreviewCardContent(
                            preview: preview,
                            knockReason: $model.knockReason,
                            isActing: model.isActing,
                            actionError: model.actionError,
                            onOpen: { model.openExisting($0) },
                            onJoin: { Task { await model.join() } },
                            onAccept: { id in Task { await model.acceptInvite(id) } },
                            onDecline: { id in Task { await model.declineInvite(id) } },
                            onKnock: { Task { await model.knock() } },
                            onCancelKnock: { id in Task { await model.cancelKnock(id) } },
                            onForget: { id in Task { await model.forget(id) } },
                            onClose: onDismiss
                        )
                        .padding(HaloSpacing.l)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .navigationTitle("Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                        .disabled(model.isActing)
                        .accessibilityIdentifier("room-preview-close")
                }
            }
            .task { await model.load() }
            .onChange(of: model.openedRoom) { _, room in
                if let room { onOpenRoom(room, model.focusEvent) }
            }
            .onChange(of: model.completedDismiss) { _, done in
                if done { onDismiss() }
            }
        }
        .accessibilityIdentifier("room-preview-sheet")
    }
}

/// Pure SwiftUI content card for `RoomPreviewSheet`, also used by Light/Dark/AX5 visual snapshot tests.
struct RoomPreviewCardContent: View {
    let preview: RoomLifecyclePreview
    @Binding var knockReason: String
    let isActing: Bool
    let actionError: String?
    let onOpen: (RoomID) -> Void
    let onJoin: () -> Void
    let onAccept: (RoomID) -> Void
    let onDecline: (RoomID) -> Void
    let onKnock: () -> Void
    let onCancelKnock: (RoomID?) -> Void
    let onForget: (RoomID?) -> Void
    let onClose: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: RoomPreviewPresentation {
        RoomLifecyclePolicy.presentation(for: preview)
    }

    private var badge: (icon: String, text: String, tint: Color) {
        switch presentation {
        case .alreadyJoined: ("checkmark.circle.fill", "Joined", HaloColor.accent)
        case .invited: ("envelope.fill", "Invited", HaloColor.accent)
        case .canJoin: ("globe", "Public room", HaloColor.accent)
        case .canKnock: ("door.left.hand.closed", "Request to join", HaloColor.accent)
        case .knocked: ("clock.fill", "Request pending", HaloColor.warning)
        case .inviteOnly: ("lock.fill", "Invite only", HaloColor.textSecondary)
        case .banned: ("hand.raised.fill", "Banned", HaloColor.danger)
        case .left: ("rectangle.portrait.and.arrow.right", "Left room", HaloColor.textSecondary)
        }
    }

    private var explanation: String? {
        switch presentation {
        case .alreadyJoined: "You're already a member of this room."
        case .invited: "You have an invitation to join this room."
        case .canJoin: nil
        case .canKnock: "This room requires approval from a room admin before you can join."
        case .knocked: "Your request to join has been sent. You'll be added once a room admin accepts."
        case .inviteOnly: "This room is invite-only. Ask a member to invite you before you can join."
        case .banned: "You were banned from this room and can't rejoin."
        case .left(_, let canRejoin):
            canRejoin ? "You left this room. You can rejoin or forget it." : "You left this room. Ask for an invite to rejoin, or forget it."
        }
    }

    var body: some View {
        VStack(spacing: HaloSpacing.l) {
            VStack(spacing: HaloSpacing.s) {
                Image(systemName: badge.icon)
                    .font(HaloTypography.title)
                    .imageScale(.large)
                    .foregroundStyle(badge.tint)
                    .accessibilityHidden(true)

                Text(preview.displayTitle)
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let topic = preview.topic, !topic.isEmpty {
                    Text(topic)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 2) {
                        Text(badge.text)
                            .font(HaloTypography.captionEmphasis)
                            .foregroundStyle(badge.tint)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let members = preview.memberCount {
                            Text(members == 1 ? "1 member" : "\(members) members")
                                .font(HaloTypography.caption)
                                .foregroundStyle(HaloColor.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    HStack(spacing: HaloSpacing.s) {
                        Text(badge.text)
                            .font(HaloTypography.captionEmphasis)
                            .foregroundStyle(badge.tint)
                        if let members = preview.memberCount {
                            Text("·")
                                .font(HaloTypography.caption)
                                .foregroundStyle(HaloColor.textSecondary)
                            Text(members == 1 ? "1 member" : "\(members) members")
                                .font(HaloTypography.caption)
                                .foregroundStyle(HaloColor.textSecondary)
                        }
                    }
                }
            }

            if let explanation {
                Text(explanation)
                    .font(HaloTypography.body)
                    .foregroundStyle(HaloColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("room-preview-explanation")
            }

            if case .canKnock = presentation {
                TextField("Optional message to room admins", text: $knockReason)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isActing)
                    .accessibilityIdentifier("room-knock-reason")
            }

            if let actionError {
                Text(actionError)
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("room-preview-error")
            }

            actionButtons
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if isActing {
            ProgressView("Working…")
                .font(HaloTypography.caption)
        } else {
            VStack(spacing: HaloSpacing.s) {
                switch presentation {
                case .alreadyJoined(let id):
                    primaryButton("Open room", id: "room-preview-open") { onOpen(id) }
                case .invited(let id):
                    primaryButton("Accept invitation", id: "room-preview-accept") { onAccept(id) }
                    destructiveButton("Decline", id: "room-preview-decline") { onDecline(id) }
                case .canJoin:
                    primaryButton("Join room", id: "room-preview-join") { onJoin() }
                case .canKnock:
                    primaryButton("Request to join", id: "room-preview-knock") { onKnock() }
                case .knocked(let id):
                    destructiveButton("Cancel request", id: "room-preview-cancel-knock") { onCancelKnock(id) }
                case .inviteOnly:
                    secondaryButton("Close", id: "room-preview-dismiss") { onClose() }
                case .banned(let id):
                    if id != nil {
                        destructiveButton("Forget room", id: "room-preview-forget") { onForget(id) }
                    }
                    secondaryButton("Close", id: "room-preview-dismiss") { onClose() }
                case .left(let id, let canRejoin):
                    if canRejoin {
                        primaryButton("Rejoin room", id: "room-preview-rejoin") { onJoin() }
                    }
                    destructiveButton("Forget room", id: "room-preview-forget") { onForget(id) }
                }
            }
        }
    }

    private func primaryButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(id)
    }

    private func secondaryButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(id)
    }

    private func destructiveButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(id)
    }
}

/// Manages `.knocked`, `.left`, and `.banned` rooms so no room can ever remain stuck (ROADMAP M20-8).
@MainActor @Observable
public final class InactiveRoomsViewModel {
    public private(set) var rooms: [RoomSummary] = []
    public private(set) var isLoading = false
    public private(set) var workingRoom: RoomID?
    public private(set) var errorMessage: String?

    @ObservationIgnored private let roomPort: any RoomPort
    @ObservationIgnored private let chats: any ChatCreationPort
    @ObservationIgnored private let actions = ActionGuard()

    public init(roomPort: any RoomPort, chats: any ChatCreationPort) {
        self.roomPort = roomPort
        self.chats = chats
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        rooms = await roomPort.inactiveRooms()
        isLoading = false
    }

    public func forget(_ room: RoomID) async {
        await run(for: room, verb: "forget this room") {
            try await self.roomPort.forget(room)
            self.rooms.removeAll { $0.id == room }
        }
    }

    public func cancelKnock(_ room: RoomID) async {
        await run(for: room, verb: "cancel this request") {
            try await self.roomPort.leave(room)
            try? await self.roomPort.forget(room)  // best-effort: some servers auto-forget cancelled knocks
            self.rooms.removeAll { $0.id == room }
        }
    }

    public func rejoin(_ room: RoomID) async -> RoomID? {
        var joined: RoomID?
        await run(for: room, verb: "rejoin this room") {
            let id = try await self.chats.joinRoom(room.rawValue)
            self.rooms.removeAll { $0.id == room }
            joined = id
        }
        return joined
    }

    private func run(for room: RoomID, verb: String, _ work: @escaping @MainActor () async throws -> Void) async {
        await actions.run("inactive:\(room.rawValue)") {
            workingRoom = room
            errorMessage = nil
            defer { workingRoom = nil }
            do {
                try await work()
            } catch let error as HaloError {
                switch error {
                case .forbidden: errorMessage = "You don't have permission to \(verb)."
                case .network: errorMessage = "You appear to be offline. Try again."
                default: errorMessage = "Couldn't \(verb). Try again."
                }
            } catch {
                errorMessage = "Couldn't \(verb). Try again."
            }
        }
    }
}

/// Lists pending join requests (knocks), left rooms, and banned rooms with clear actions (M20-8: zero stuck rows).
public struct InactiveRoomsView: View {
    @State private var model: InactiveRoomsViewModel
    private let onOpenRoom: @MainActor (RoomID) -> Void

    public init(model: InactiveRoomsViewModel, onOpenRoom: @escaping @MainActor (RoomID) -> Void) {
        _model = State(initialValue: model)
        self.onOpenRoom = onOpenRoom
    }

    public var body: some View {
        Group {
            if model.isLoading && model.rooms.isEmpty {
                LoadingState()
            } else if model.rooms.isEmpty {
                EmptyState(
                    icon: "tray",
                    title: "No left or pending rooms",
                    message: "Pending join requests, left rooms and banned rooms appear here so you can manage or forget them."
                )
            } else {
                List {
                    if let error = model.errorMessage {
                        Section {
                            Text(error)
                                .font(HaloTypography.meta)
                                .foregroundStyle(HaloColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(model.rooms) { room in
                        InactiveRoomRow(
                            room: room,
                            isWorking: model.workingRoom == room.id,
                            onOpenSuccessor: { id in onOpenRoom(id) },
                            onRejoin: {
                                Task {
                                    if let id = await model.rejoin(room.id) { onOpenRoom(id) }
                                }
                            },
                            onCancelKnock: { Task { await model.cancelKnock(room.id) } },
                            onForget: { Task { await model.forget(room.id) } }
                        )
                    }
                }
            }
        }
        .navigationTitle("Left & Pending Rooms")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("inactive-rooms-view")
    }
}

struct InactiveRoomRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let room: RoomSummary
    let isWorking: Bool
    let onOpenSuccessor: (RoomID) -> Void
    let onRejoin: () -> Void
    let onCancelKnock: () -> Void
    let onForget: () -> Void

    private var statusText: String {
        switch room.membership {
        case .knocked: "Join request pending"
        case .banned: "Banned"
        case .left: room.successor != nil ? "Upgraded · Left" : "Left"
        case .joined, .invited: ""
        }
    }

    private var statusColor: Color {
        switch room.membership {
        case .knocked: HaloColor.warning
        case .banned: HaloColor.danger
        default: HaloColor.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name ?? room.id.rawValue)
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusText)
                    .font(HaloTypography.captionEmphasis)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: HaloSpacing.xs) { buttons(fullWidth: true) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: HaloSpacing.s) { buttons(fullWidth: false) }
                    VStack(alignment: .leading, spacing: HaloSpacing.xs) { buttons(fullWidth: true) }
                }
            }
        }
        .padding(.vertical, HaloSpacing.xs)
        .accessibilityIdentifier("inactive-room-\(room.id.rawValue)")
    }

    @ViewBuilder
    private func buttonLabel(_ title: LocalizedStringKey, fullWidth: Bool) -> some View {
        Text(title)
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: fullWidth ? .infinity : nil)
    }

    @ViewBuilder
    private func buttons(fullWidth: Bool) -> some View {
        if let successor = room.successor {
            Button {
                onOpenSuccessor(successor.roomID)
            } label: {
                buttonLabel("Go to new room", fullWidth: fullWidth)
            }
            .buttonStyle(.borderedProminent)
        }
        switch room.membership {
        case .knocked:
            Button(role: .destructive) {
                onCancelKnock()
            } label: {
                buttonLabel("Cancel request", fullWidth: fullWidth)
            }
            .buttonStyle(.bordered)
        case .left:
            if room.successor == nil {
                Button {
                    onRejoin()
                } label: {
                    buttonLabel("Rejoin", fullWidth: fullWidth)
                }
                .buttonStyle(.bordered)
            }
            Button(role: .destructive) {
                onForget()
            } label: {
                buttonLabel("Forget", fullWidth: fullWidth)
            }
            .buttonStyle(.bordered)
        case .banned:
            Button(role: .destructive) {
                onForget()
            } label: {
                buttonLabel("Forget", fullWidth: fullWidth)
            }
            .buttonStyle(.bordered)
        case .joined, .invited:
            EmptyView()
        }
    }
}
#endif
