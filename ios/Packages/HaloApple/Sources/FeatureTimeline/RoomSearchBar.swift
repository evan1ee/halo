#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// In-room search bar pinned at the top of a timeline with previous (older) / next (newer) match stepping,
/// empty/indexing/offline/error states, and full AX5 Dynamic Type & VoiceOver support (ROADMAP M20-11).
public struct RoomSearchBar: View {
    @Bindable private var model: RoomSearchViewModel
    private let onOpenThreadMessage: (@MainActor (EventID, EventID) -> Void)?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(
        model: RoomSearchViewModel,
        onOpenThreadMessage: (@MainActor (EventID, EventID) -> Void)? = nil
    ) {
        self.model = model
        self.onOpenThreadMessage = onOpenThreadMessage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
            searchInputRow
            if showsNavigationRow {
                navigationRow
            }
            if let error = model.errorMessage {
                errorRow(error)
            }
            if let notice = model.indexNotice {
                indexingRow(notice)
            }
        }
        .padding(.horizontal, HaloSpacing.m)
        .padding(.vertical, HaloSpacing.s)
        .haloBarBackground()
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-search-bar")
        .onAppear {
            fieldFocused = true
        }
    }

    private var showsNavigationRow: Bool {
        !model.trimmedQuery.isEmpty && model.errorMessage == nil
    }

    private var searchInputRow: some View {
        HStack(spacing: HaloSpacing.s) {
            HStack(spacing: HaloSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.textSecondary)
                    .accessibilityHidden(true)
                TextField("Search in chat", text: $model.query)
                    .font(HaloTypography.body)
                    .foregroundStyle(HaloColor.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($fieldFocused)
                    .onSubmit { model.submit() }
                    .accessibilityLabel("Search in chat")
                    .accessibilityIdentifier("room-search-field")
                if !model.query.isEmpty {
                    Button {
                        model.clearQuery()
                        fieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(HaloTypography.meta)
                            .foregroundStyle(HaloColor.textSecondary)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier("room-search-clear")
                }
            }
            .padding(.horizontal, HaloSpacing.s)
            .padding(.vertical, HaloSpacing.xs)
            .frame(minHeight: 36)
            .background(HaloColor.bgSecondary, in: .rect(cornerRadius: HaloRadius.medium, style: .continuous))

            Button("Done") {
                fieldFocused = false
                model.close()
            }
            .font(HaloTypography.bodyEmphasis)
            .foregroundStyle(HaloColor.accent)
            .frame(minHeight: 44)
            .accessibilityIdentifier("room-search-done")
        }
    }

    @ViewBuilder
    private var navigationRow: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                HStack(spacing: HaloSpacing.s) {
                    matchStatusLabel
                    Spacer(minLength: HaloSpacing.xs)
                    stepButtons
                }
                if let thread = model.selectedThreadMatch, let onOpenThreadMessage {
                    threadMatchButton(thread, action: onOpenThreadMessage)
                }
            }
        } else {
            HStack(spacing: HaloSpacing.s) {
                matchStatusLabel
                if let thread = model.selectedThreadMatch, let onOpenThreadMessage {
                    threadMatchButton(thread, action: onOpenThreadMessage)
                }
                Spacer(minLength: HaloSpacing.xs)
                stepButtons
            }
        }
    }

    @ViewBuilder
    private var matchStatusLabel: some View {
        if model.isLoading && model.navigator.hits.isEmpty {
            HStack(spacing: HaloSpacing.xs) {
                ProgressView().controlSize(.small)
                Text("Searching…")
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("room-search-loading")
        } else if model.showsEmptyState {
            Text(model.emptyStateText)
                .font(HaloTypography.meta)
                .foregroundStyle(HaloColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("room-search-empty")
        } else if let position = model.positionText {
            HStack(spacing: HaloSpacing.xs) {
                Text(position)
                    .font(HaloTypography.meta.monospacedDigit())
                    .foregroundStyle(HaloColor.textSecondary)
                    .accessibilityLabel("Match \(position)")
                    .accessibilityIdentifier("room-search-count")
                if model.isLoadingMore || model.isJumping {
                    ProgressView().controlSize(.mini)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var stepButtons: some View {
        HStack(spacing: HaloSpacing.xxs) {
            Button {
                fieldFocused = false
                model.stepPrevious()
            } label: {
                Image(systemName: "chevron.up")
                    .font(HaloTypography.bodyEmphasis)
                    .frame(width: 44, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canStepPrevious ? HaloColor.accent : HaloColor.textSecondary.opacity(0.4))
            .disabled(!model.canStepPrevious)
            .accessibilityLabel("Previous match")
            .accessibilityHint("Jumps to an older matching message")
            .accessibilityIdentifier("room-search-prev")

            Button {
                fieldFocused = false
                model.stepNext()
            } label: {
                Image(systemName: "chevron.down")
                    .font(HaloTypography.bodyEmphasis)
                    .frame(width: 44, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.canStepNext ? HaloColor.accent : HaloColor.textSecondary.opacity(0.4))
            .disabled(!model.canStepNext)
            .accessibilityLabel("Next match")
            .accessibilityHint("Jumps to a newer matching message")
            .accessibilityIdentifier("room-search-next")
        }
    }

    private func threadMatchButton(
        _ match: RoomSearchViewModel.ThreadMatch,
        action: @escaping @MainActor (EventID, EventID) -> Void
    ) -> some View {
        Button {
            fieldFocused = false
            action(match.rootEvent, match.eventID)
        } label: {
            Label("Open thread", systemImage: "bubble.left.and.text.bubble.right")
                .font(HaloTypography.caption.weight(.medium))
                .foregroundStyle(HaloColor.accent)
                .padding(.horizontal, HaloSpacing.s)
                .padding(.vertical, HaloSpacing.xs)
                .background(HaloColor.accent.opacity(0.14), in: .rect(cornerRadius: HaloRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 32)
        .accessibilityIdentifier("room-search-open-thread")
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: HaloSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(HaloTypography.caption)
                .foregroundStyle(HaloColor.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(HaloTypography.caption)
                .foregroundStyle(HaloColor.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: HaloSpacing.xs)
            Button("Try again") { model.retry() }
                .font(HaloTypography.caption.weight(.semibold))
                .foregroundStyle(HaloColor.accent)
                .accessibilityIdentifier("room-search-retry")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("room-search-error")
    }

    private func indexingRow(_ notice: RoomSearchIndexNotice) -> some View {
        HStack(alignment: .center, spacing: HaloSpacing.xs) {
            if notice.isIndexing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: notice.isOffline ? "wifi.slash" : "clock.arrow.circlepath")
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(notice.text)
                .font(HaloTypography.caption)
                .foregroundStyle(HaloColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room-search-status")
    }
}
#endif
