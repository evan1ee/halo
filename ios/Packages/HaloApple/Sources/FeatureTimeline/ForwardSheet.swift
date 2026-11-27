#if canImport(SwiftUI)
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import Observation
import SwiftUI

/// Drives the multi-target Forward sheet with encryption-downgrade confirmation and partial-failure retry (MESSAGING FR-8, M20-6).
@MainActor @Observable
public final class ForwardViewModel {
    public let payload: ForwardPayload
    public private(set) var sourceIsEncrypted = false
    public private(set) var targets: [ForwardTarget] = []
    public var query = ""
    public private(set) var selected: [RoomID] = []
    public private(set) var isLoadingTargets = false
    public private(set) var isSending = false
    public private(set) var encryptionWarning: String?
    public private(set) var errorMessage: String?
    public private(set) var completed = false

    @ObservationIgnored private let forwarder: ForwardCoordinator
    @ObservationIgnored private let loadTargets: @Sendable () async -> (sourceIsEncrypted: Bool, targets: [ForwardTarget])
    @ObservationIgnored private let actions = ActionGuard()

    public init(
        payload: ForwardPayload,
        forwarder: ForwardCoordinator,
        loadTargets: @escaping @Sendable () async -> (sourceIsEncrypted: Bool, targets: [ForwardTarget])
    ) {
        self.payload = payload
        self.forwarder = forwarder
        self.loadTargets = loadTargets
    }

    /// Targets matching the search field.
    public var filteredTargets: [ForwardTarget] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return targets }
        return targets.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Currently chosen `ForwardTarget` values in selection order.
    public var selectedTargets: [ForwardTarget] {
        let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        return selected.compactMap { byID[$0] }
    }

    public var canSubmit: Bool { !selected.isEmpty && !isSending && !isLoadingTargets }

    public func load() async {
        guard targets.isEmpty, !isLoadingTargets else { return }
        isLoadingTargets = true
        let result = await loadTargets()
        sourceIsEncrypted = result.sourceIsEncrypted
        targets = result.targets
        isLoadingTargets = false
    }

    public func isSelected(_ room: RoomID) -> Bool {
        selected.contains(room)
    }

    public func toggle(_ room: RoomID) {
        guard !isSending else { return }
        errorMessage = nil
        if let idx = selected.firstIndex(of: room) {
            selected.remove(at: idx)
        } else {
            selected.append(room)
        }
    }

    /// Checks encryption policy first: warns before leaving an encrypted room, otherwise sends immediately.
    public func requestForward() async {
        guard canSubmit else { return }
        if let warning = ForwardPolicy.encryptionWarning(sourceIsEncrypted: sourceIsEncrypted, targets: selectedTargets) {
            encryptionWarning = warning
            return
        }
        await performForward()
    }

    /// Confirms forwarding after the user explicitly accepts the unencrypted-destination warning.
    public func confirmForwardLeavingEncryption() async {
        encryptionWarning = nil
        await performForward()
    }

    public func cancelEncryptionWarning() {
        encryptionWarning = nil
    }

    private func performForward() async {
        let destinations = selected
        guard !destinations.isEmpty else { return }
        await actions.run("forward") {
            isSending = true
            errorMessage = nil
            defer { isSending = false }
            let outcome = await forwarder.forward(payload, to: destinations)
            if outcome.isCompleteSuccess {
                selected = []
                completed = true
                return
            }
            let failedSet = Set(outcome.failedRoomIDs)
            // Keep only failed destinations selected so tapping Forward again retries just those chats.
            selected = destinations.filter { failedSet.contains($0) }
            let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.name) })
            let failedNames = selected.compactMap { byID[$0] }
            if outcome.succeeded.isEmpty {
                let anyNetwork = outcome.failed.values.contains {
                    if case .network = $0 { return true }
                    return false
                }
                errorMessage = anyNetwork
                    ? "Can't reach the server. Nothing was forwarded."
                    : "Couldn't forward to \(failedNames.isEmpty ? "the selected chats" : failedNames.joined(separator: ", "))."
            } else {
                let sentCount = outcome.succeeded.count
                let sentLabel = sentCount == 1 ? "1 chat" : "\(sentCount) chats"
                let failedLabel = failedNames.isEmpty ? "\(selected.count) remaining" : failedNames.joined(separator: ", ")
                errorMessage = "Forwarded to \(sentLabel), but couldn't send to \(failedLabel). Tap Forward to retry."
            }
        }
    }
}

/// Searchable multi-target chat picker for forwarding a message (MESSAGING FR-8, AC-M4, M20-6).
struct ForwardSheet: View {
    @State var model: ForwardViewModel
    let onDismiss: () -> Void

    private var sendTitle: String {
        model.selected.count > 1 ? "Forward (\(model.selected.count))" : "Forward"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForwardPreviewBanner(payload: model.payload)
                } header: {
                    Text("Message")
                }

                if let error = model.errorMessage {
                    Section {
                        Text(error)
                            .font(HaloTypography.meta)
                            .foregroundStyle(HaloColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("forward-error")
                    }
                }

                Section {
                    if model.isLoadingTargets {
                        HStack(spacing: HaloSpacing.s) {
                            ProgressView()
                            Text("Loading chats…")
                                .font(HaloTypography.meta)
                                .foregroundStyle(HaloColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, HaloSpacing.m)
                    } else if model.filteredTargets.isEmpty {
                        Text(model.targets.isEmpty ? "No chats available." : "No chats match.")
                            .font(HaloTypography.meta)
                            .foregroundStyle(HaloColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, HaloSpacing.m)
                    } else {
                        ForEach(model.filteredTargets) { target in
                            targetRow(target)
                        }
                    }
                } header: {
                    Text("Send to")
                }
            }
            .searchable(text: $model.query, prompt: "Search chats")
            .navigationTitle("Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .disabled(model.isSending)
                        .accessibilityIdentifier("forward-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSending {
                        HStack(spacing: HaloSpacing.xs) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Forwarding…")
                                .font(HaloTypography.caption)
                        }
                        .accessibilityLabel("Forwarding")
                    } else {
                        Button(sendTitle) {
                            Task { await model.requestForward() }
                        }
                        .disabled(!model.canSubmit)
                        .accessibilityIdentifier("forward-send")
                    }
                }
            }
            .interactiveDismissDisabled(model.isSending)
            .alert(
                "Forward to unencrypted chat?",
                isPresented: Binding(
                    get: { model.encryptionWarning != nil },
                    set: { if !$0 { model.cancelEncryptionWarning() } }
                )
            ) {
                Button("Forward anyway", role: .destructive) {
                    Task { await model.confirmForwardLeavingEncryption() }
                }
                Button("Cancel", role: .cancel) {
                    model.cancelEncryptionWarning()
                }
            } message: {
                Text(model.encryptionWarning ?? "")
            }
            .task { await model.load() }
            .onChange(of: model.completed) { _, done in
                if done { onDismiss() }
            }
        }
        .accessibilityIdentifier("forward-sheet")
    }

    @ViewBuilder
    private func targetRow(_ target: ForwardTarget) -> some View {
        ForwardTargetRow(
            target: target,
            selected: model.isSelected(target.id),
            leavesEncryption: model.sourceIsEncrypted && !target.isEncrypted,
            disabled: model.isSending
        ) {
            model.toggle(target.id)
        }
    }
}

/// Preview header rendered inside `ForwardSheet` (also unit-snapshotted in Light, Dark, and AX5).
struct ForwardPreviewBanner: View {
    let payload: ForwardPayload
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: HaloSpacing.s) {
            Image(systemName: payload.systemImage)
                .font(HaloTypography.bodyEmphasis)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(HaloColor.accent)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(payload.previewSummary)
                .font(HaloTypography.body)
                .foregroundStyle(HaloColor.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Forwarding: \(payload.previewSummary)")
        .accessibilityIdentifier("forward-preview")
    }
}

/// Selectable chat row rendered inside `ForwardSheet` showing encryption state and downgrade warning hint.
struct ForwardTargetRow: View {
    let target: ForwardTarget
    let selected: Bool
    let leavesEncryption: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HaloSpacing.s) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(HaloTypography.body)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .foregroundStyle(selected ? HaloColor.accent : HaloColor.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                        .font(selected ? HaloTypography.bodyEmphasis : HaloTypography.body)
                        .foregroundStyle(HaloColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if leavesEncryption {
                        HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                            Image(systemName: "lock.open")
                                .font(HaloTypography.caption)
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .accessibilityHidden(true)
                            Text("Not encrypted")
                                .font(HaloTypography.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(HaloColor.warning)
                    } else if target.isEncrypted {
                        HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.xs) {
                            Image(systemName: "lock.fill")
                                .font(HaloTypography.caption)
                                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                .accessibilityHidden(true)
                            Text("Encrypted")
                                .font(HaloTypography.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(HaloColor.textSecondary)
                    }
                }
                Spacer(minLength: HaloSpacing.xs)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(target.name), \(target.isEncrypted ? "encrypted" : "not encrypted")")
        .accessibilityIdentifier("forward-target-\(target.id.rawValue)")
    }
}
#endif
