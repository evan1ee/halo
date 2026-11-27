#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// Interactive MSC3381 poll card rendered inside a timeline bubble (MESSAGING FR-10, AC-M5, M20-4).
///
/// Supports single-choice and multi-select voting, changing votes, live disclosed results, undisclosed polls
/// (counts hidden until ended), honest pending states while waiting for server confirmation, and ending own polls.
struct PollCardView: View {
    let row: TimelineRow
    let poll: PollDetails
    let model: TimelineViewModel
    let isOwn: Bool

    @State private var confirmingEnd = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var pendingSelection: [String]? {
        row.eventID.flatMap { model.pendingPollVotes[$0] }
    }

    private var isEnding: Bool {
        row.eventID.map { model.endingPolls.contains($0) } ?? false
    }

    private var errorText: String? {
        row.eventID.flatMap { model.pollErrors[$0] }
    }

    private var isPendingVote: Bool { pendingSelection != nil }
    private var canVote: Bool { !poll.ended && row.eventID != nil && !isEnding }
    private var isMultiSelect: Bool { poll.maxSelections > 1 }

    private var footerSummary: String {
        if isEnding { return "Ending poll…" }
        if isPendingVote { return "Sending vote…" }
        let voters = poll.totalVoters
        let voteCount = voters == 1 ? "1 vote" : "\(voters) votes"
        if poll.ended {
            return voters == 0 ? "Poll ended · No votes" : "Poll ended · \(voteCount)"
        }
        if !poll.showsResults {
            return voters == 0 ? "Results hidden until poll ends" : "\(voteCount) · Results hidden until poll ends"
        }
        if isMultiSelect {
            let prefix = voters == 0 ? "Choose up to \(poll.maxSelections)" : "\(voteCount) · Up to \(poll.maxSelections)"
            return prefix
        }
        return voters == 0 ? "No votes yet" : voteCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.s) {
            HStack(alignment: .top, spacing: HaloSpacing.xs) {
                Image(systemName: "chart.bar.xaxis")
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.accent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                Text(poll.question)
                    .font(HaloTypography.headline)
                    .foregroundStyle(HaloColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: HaloSpacing.s) {
                ForEach(poll.options) { option in
                    optionRow(option)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(HaloTypography.caption)
                    .foregroundStyle(HaloColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("poll-error")
            }

            footerRow
        }
        .padding(HaloSpacing.m)
        .frame(minWidth: 230, maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 280, alignment: .leading)
        .background(
            isOwn ? HaloColor.bubbleOwn : HaloColor.bubbleOther,
            in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous)
        )
        .opacity(row.status == nil ? 1 : 0.6)
        .accessibilityIdentifier("poll-card")
        .alert("End this poll?", isPresented: $confirmingEnd) {
            Button("End poll", role: .destructive) {
                Task { await model.endPoll(row) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone will see the final results and no more votes can be cast.")
        }
    }

    @ViewBuilder
    private func optionRow(_ option: PollOption) -> some View {
        let confirmedSelected = option.selectedByMe
        let pendingSelected = pendingSelection?.contains(option.id) ?? false
        let isPendingTarget = isPendingVote && pendingSelected != confirmedSelected
        let visuallySelected = isPendingVote ? pendingSelected : confirmedSelected
        let isWinner = poll.isWinner(option)
        let fraction = poll.showsResults ? poll.voteFraction(for: option) : 0
        let pct = poll.votePercentage(for: option)

        Button {
            Task { await model.votePoll(row, optionID: option.id) }
        } label: {
            optionLabelContent(
                option: option,
                visuallySelected: visuallySelected,
                isPendingTarget: isPendingTarget,
                isWinner: isWinner,
                percentage: pct
            )
            .padding(.horizontal, HaloSpacing.s)
            .padding(.vertical, HaloSpacing.s)
            .frame(minHeight: 44, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous)
                        .fill(HaloColor.bgPrimary.opacity(0.65))

                    if poll.showsResults, fraction > 0 {
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous)
                                .fill(HaloColor.accent.opacity(visuallySelected || isWinner ? 0.24 : 0.12))
                                .frame(width: max(6, geometry.size.width * fraction))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous))
            }
            .overlay {
                if isPendingTarget {
                    RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous)
                        .strokeBorder(HaloColor.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                } else if visuallySelected || isWinner {
                    RoundedRectangle(cornerRadius: HaloRadius.small, style: .continuous)
                        .strokeBorder(HaloColor.accent.opacity(isWinner ? 0.7 : 0.45), lineWidth: 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(ScrollFriendlyTapButtonStyle())
        .disabled(!canVote)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(optionAccessibilityLabel(option, visuallySelected: visuallySelected, isPendingTarget: isPendingTarget, isWinner: isWinner, percentage: pct))
        .accessibilityHint(canVote ? (visuallySelected ? "Selected" : "Votes for this option") : "")
        .accessibilityAddTraits(visuallySelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("poll-option-\(option.id)")
    }

    @ViewBuilder
    private func optionLabelContent(
        option: PollOption,
        visuallySelected: Bool,
        isPendingTarget: Bool,
        isWinner: Bool,
        percentage: Int
    ) -> some View {
        let indicator = optionIndicator(visuallySelected: visuallySelected, isPendingTarget: isPendingTarget, isWinner: isWinner)
        let title = Text(option.text)
            .font(isWinner || visuallySelected ? HaloTypography.bodyEmphasis : HaloTypography.body)
            .foregroundStyle(HaloColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        let resultText = "\(option.votes) · \(percentage)%"

        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                HStack(alignment: .top, spacing: HaloSpacing.s) {
                    indicator
                    title
                }
                if poll.showsResults {
                    Text(resultText)
                        .font(HaloTypography.captionEmphasis.monospacedDigit())
                        .foregroundStyle(isWinner || visuallySelected ? HaloColor.accent : HaloColor.textSecondary)
                }
            }
        } else {
            HStack(alignment: .center, spacing: HaloSpacing.s) {
                indicator
                title
                if poll.showsResults {
                    Text(resultText)
                        .font(HaloTypography.captionEmphasis.monospacedDigit())
                        .foregroundStyle(isWinner || visuallySelected ? HaloColor.accent : HaloColor.textSecondary)
                        .fixedSize()
                }
            }
        }
    }

    @ViewBuilder
    private func optionIndicator(visuallySelected: Bool, isPendingTarget: Bool, isWinner: Bool) -> some View {
        if isPendingTarget {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 20, height: 20)
        } else if poll.ended {
            Image(systemName: isWinner ? "checkmark.seal.fill" : (visuallySelected ? "checkmark.circle.fill" : "circle"))
                .font(HaloTypography.body)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(isWinner || visuallySelected ? HaloColor.accent : HaloColor.textSecondary.opacity(0.6))
                .frame(width: 20, height: 20)
        } else {
            let symbol: String = if isMultiSelect {
                visuallySelected ? "checkmark.square.fill" : "square"
            } else {
                visuallySelected ? "checkmark.circle.fill" : "circle"
            }
            Image(systemName: symbol)
                .font(HaloTypography.body)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(visuallySelected ? HaloColor.accent : HaloColor.textSecondary)
                .frame(width: 20, height: 20)
        }
    }

    @ViewBuilder
    private var footerRow: some View {
        let statusView = HStack(spacing: HaloSpacing.xs) {
            if isPendingVote || isEnding {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(footerSummary)
                .font(HaloTypography.caption)
                .foregroundStyle(isPendingVote || isEnding ? HaloColor.accent : HaloColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("poll-status")

        let canEnd = row.isOwn && !poll.ended && row.eventID != nil && !isEnding
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                statusView
                if canEnd { endPollButton }
            }
        } else {
            HStack(spacing: HaloSpacing.s) {
                statusView
                Spacer(minLength: HaloSpacing.xs)
                if canEnd { endPollButton }
            }
        }
    }

    private var endPollButton: some View {
        Button("End poll") {
            confirmingEnd = true
        }
        .font(HaloTypography.captionEmphasis)
        .foregroundStyle(HaloColor.danger)
        .buttonStyle(.plain)
        .accessibilityIdentifier("poll-end-button")
    }

    private func optionAccessibilityLabel(
        _ option: PollOption,
        visuallySelected: Bool,
        isPendingTarget: Bool,
        isWinner: Bool,
        percentage: Int
    ) -> String {
        var parts = [option.text]
        if isPendingTarget {
            parts.append("sending vote")
        } else if visuallySelected {
            parts.append("selected")
        }
        if isWinner {
            parts.append("winner")
        }
        if poll.showsResults {
            let noun = option.votes == 1 ? "vote" : "votes"
            parts.append("\(option.votes) \(noun), \(percentage) percent")
        }
        return parts.joined(separator: ", ")
    }
}
#endif
