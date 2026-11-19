#if canImport(SwiftUI)
import SwiftUI

public struct TimelineView: View {
    private let model: TimelineViewModel

    public init(model: TimelineViewModel) { self.model = model }

    public var body: some View {
        Group {
            switch model.content {
            case .opening:
                ProgressView()
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            case .live(let rows, let isPaginating, let canLoadEarlier, let paginationError):
                List {
                    if canLoadEarlier {
                        HStack {
                            Spacer()
                            if isPaginating {
                                ProgressView()
                            } else {
                                Button(paginationError ?? "Load earlier messages") { Task { await model.loadEarlier() } }
                                    .font(.footnote)
                            }
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        // Re-runs whenever rows change, so loading continues until the start marker arrives.
                        .task(id: rows.count) { if paginationError == nil { await model.loadEarlier() } }
                    }
                    ForEach(rows) { row in RowView(row: row).listRowSeparator(.hidden) }
                }
                .listStyle(.plain)
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier("timeline")
            }
        }
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }
}

private struct RowView: View {
    let row: TimelineRow

    var body: some View {
        switch row.style {
        case .message, .ownMessage:
            VStack(alignment: row.style == .ownMessage ? .trailing : .leading, spacing: 2) {
                if let sender = row.sender, row.style == .message { Text(sender).font(.caption).foregroundStyle(.secondary) }
                Text(row.text)
                    .padding(8)
                    .background(row.style == .ownMessage ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 12))
            }
            .frame(maxWidth: .infinity, alignment: row.style == .ownMessage ? .trailing : .leading)
        case .notice:
            Text(row.text).font(.callout).foregroundStyle(.secondary)
        case .emote:
            Text(row.text).italic()
        case .placeholder:
            Text(row.text).italic().foregroundStyle(.secondary)
        case .state, .marker:
            Text(row.text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        case .divider:
            Text(row.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}
#endif
