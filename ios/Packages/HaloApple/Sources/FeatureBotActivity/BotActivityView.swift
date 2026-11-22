#if canImport(SwiftUI)
import HaloApplication
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import SwiftUI

/// The Activity screen: tasks and reminders from the bots the user trusts, across rooms (docs/features/BOT_ACTIVITY.md).
public struct BotActivityView: View {
    @State private var model: BotActivityViewModel
    @State private var confirmingRebuild = false
    private let open: (RoomID, EventID?) -> Void
    @Environment(\.dismiss) private var dismiss

    /// - Parameter open: opens the room of an item (the event is the message the task came from, when known).
    public init(model: BotActivityViewModel, open: @escaping (RoomID, EventID?) -> Void) {
        _model = State(initialValue: model)
        self.open = open
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .loading: LoadingState(.roomList(count: 5))
            case .failed:
                ErrorState(title: "Couldn't load Activity", message: "Check your connection and try again.") {
                    Task { await model.load() }
                }
            case .loaded: content
            }
        }
        .navigationTitle("Activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            if model.phase == .loaded {
                ToolbarItem(placement: .primaryAction) { filterMenu }
            }
        }
        .confirmationDialog("Rebuild the list?", isPresented: $confirmingRebuild, titleVisibility: .visible) {
            Button("Rebuild", role: .destructive) { Task { await model.rebuild() } }
        } message: {
            Text("This empties the list. It fills again as you open rooms with your bots and as they write.")
        }
        .task { await model.load() }
        .task { await model.observeActions() }
    }

    @ViewBuilder private var content: some View {
        let sections = model.sections
        List {
            Section {
            } footer: {
                Text("From messages on this device. Halo only knows what your bots said in rooms you have opened here, or whose newest message is from a bot; the bot's own list is the truth.")
            }
            if sections.isEmpty {
                ContentUnavailableView(
                    "Nothing yet", systemImage: "checklist",
                    description: Text("Tasks and reminders from your bots show up here once you open their rooms."))
                    .listRowBackground(Color.clear)
            }
            section("Open", sections.open)
            section("Reminders", sections.reminders)
            section("Completed this week", sections.completed)
            Section {
                Button("Rebuild list", role: .destructive) { confirmingRebuild = true }
            }
        }
        .refreshable { await model.load() }
    }

    @ViewBuilder private func section(_ title: String, _ items: [BotActivityViewModel.Item]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        if item.canTick || item.tickState != nil { tickControl(item) }
                        Button { open(item.key.room, item.sourceEventID) } label: { row(item) }
                            .buttonStyle(.plain)
                    }
                    .contextMenu {
                        #if canImport(UIKit)
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.title }
                        #endif
                    }
                }
            }
        }
    }

    /// The round tick button: a circle to tap, a spinner while the bot's answer is awaited (never a check before the bot confirms).
    @ViewBuilder private func tickControl(_ item: BotActivityViewModel.Item) -> some View {
        if item.tickState == .pending {
            ProgressView().frame(width: 28, height: 28).accessibilityLabel("Waiting for the bot")
        } else {
            Button { Task { await model.tick(item) } } label: {
                Image(systemName: item.tickState == nil ? "circle" : "exclamationmark.circle").font(.title2).foregroundStyle(item.tickState == nil ? HaloColor.accent : HaloColor.warning)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark as done")
            .accessibilityIdentifier("tick-\(item.key.id)")
        }
    }

    private func row(_ item: BotActivityViewModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
            if let detail = item.detail, !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Text("\(item.roomName) · \(item.botName) · as of \(item.asOf.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
            if item.sourceDeleted { Text("Its message was deleted").font(.caption).foregroundStyle(.secondary) }
            if let status = tickStatus(item.tickState) { Text(status).font(HaloTypography.caption).foregroundStyle(HaloColor.warning) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func tickStatus(_ state: BotActionCoordinator.State?) -> String? {
        switch state {
        case .pending: "Waiting for bot…"
        case .failed: "That didn't work. Tap to try again."
        case .noResponse: "No response from bot. Tap to try again."
        case nil: nil
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Room", selection: $model.roomFilter) {
                Text("All rooms").tag(RoomID?.none)
                ForEach(model.roomChoices, id: \.id) { Text($0.name).tag(RoomID?.some($0.id)) }
            }
            Picker("Bot", selection: $model.botFilter) {
                Text("All bots").tag(String?.none)
                ForEach(model.botChoices, id: \.self) { Text($0).tag(String?.some($0)) }
            }
        } label: {
            Image(systemName: model.roomFilter == nil && model.botFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter")
    }
}
#endif
