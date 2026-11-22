#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI

/// Visual state of a single interactive row inside a `BotCardView` (BOT_MESSAGES FR-2/FR-3).
public enum BotCardRowState: Sendable, Equatable {
    case open
    case pending
    case completed
    case noResponse
    case unavailable
}

/// Renders a parsed Layer 2 bot template as a native Halo card (`docs/features/BOT_MESSAGES.md` FR-2, ADR-0022).
public struct BotCardView: View {
    private let card: BotCard
    private let state: (String) -> BotCardRowState
    private let tick: (String) -> Void

    public init(
        card: BotCard,
        state: @escaping (String) -> BotCardRowState,
        tick: @escaping (String) -> Void
    ) {
        self.card = card
        self.state = state
        self.tick = tick
    }

    private func todoRow(_ row: BotCard.TodoRow) -> some View {
        let rowState = row.isDone ? .completed : state(row.id)
        let done = rowState == .completed
        return HStack(alignment: .firstTextBaseline, spacing: HaloSpacing.s) {
            Button { tick(row.id) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : (rowState == .pending ? "clock" : "circle"))
                    .foregroundStyle(done ? HaloColor.success : HaloColor.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(rowState != .open && rowState != .noResponse)
            .accessibilityLabel(done ? "Done" : "Mark done")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: HaloSpacing.xs) {
                    Text(row.text)
                        .strikethrough(done)
                        .foregroundStyle(done ? HaloColor.textSecondary : HaloColor.textPrimary)
                    Text("#\(row.id)")
                        .font(.caption2)
                        .foregroundStyle(HaloColor.textSecondary)
                }
                switch rowState {
                case .pending:
                    Text("Waiting for bot…").font(.caption2).foregroundStyle(HaloColor.textSecondary)
                case .noResponse:
                    Text("No response from bot. Tap to try again.").font(.caption2).foregroundStyle(HaloColor.warning)
                case .unavailable where !row.isDone:
                    Text("Not available").font(.caption2).foregroundStyle(HaloColor.textSecondary)
                default:
                    EmptyView()
                }
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HaloSpacing.xs) {
            switch card {
            case .todoList(let title, let rows):
                Label(title, systemImage: "checklist").font(HaloTypography.meta.weight(.bold))
                ForEach(rows, id: \.id) { row in todoRow(row) }
            case .taskAdded(let id, let owner, let title):
                Label("Task #\(id) added", systemImage: "plus.circle").font(HaloTypography.meta.weight(.bold))
                Text(title)
                if let owner { Text("for \(owner)").font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary) }
            case .reminderSet(let id, let when, let title):
                Label("Reminder #\(id)", systemImage: "alarm").font(HaloTypography.meta.weight(.bold))
                Text(title)
                if let when { Text(when).font(HaloTypography.caption).foregroundStyle(HaloColor.textSecondary) }
            case .taskDone(let title):
                Label("Done: \(title)", systemImage: "checkmark.circle.fill").foregroundStyle(HaloColor.success)
            case .taskDeleted(let title):
                Label("Deleted: \(title)", systemImage: "trash").foregroundStyle(HaloColor.textSecondary)
            }
        }
        .padding(HaloSpacing.m)
        .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
        .accessibilityIdentifier("bot-card")
    }
}
#endif
