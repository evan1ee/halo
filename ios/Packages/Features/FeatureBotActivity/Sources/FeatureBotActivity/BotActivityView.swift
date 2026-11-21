#if canImport(SwiftUI)
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
        NavigationStack {
            Group {
                switch model.phase {
                case .loading: ProgressView()
                case .failed:
                    ContentUnavailableView {
                        Label("Couldn't load Activity", systemImage: "exclamationmark.triangle")
                    } actions: {
                        Button("Try again") { Task { await model.load() } }.buttonStyle(.borderedProminent)
                    }
                case .loaded: content
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if model.phase == .loaded {
                    ToolbarItem(placement: .cancellationAction) { filterMenu }
                }
            }
            .confirmationDialog("Rebuild the list?", isPresented: $confirmingRebuild, titleVisibility: .visible) {
                Button("Rebuild", role: .destructive) { Task { await model.rebuild() } }
            } message: {
                Text("This empties the list. It fills again as you open rooms with your bots.")
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        let sections = model.sections
        List {
            Section {
            } footer: {
                Text("From messages on this device. Halo only knows what your bots said in rooms you have opened here; the bot's own list is the truth.")
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
                    Button { open(item.key.room, item.sourceEventID) } label: { row(item) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            #if canImport(UIKit)
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.title }
                            #endif
                        }
                }
            }
        }
    }

    private func row(_ item: BotActivityViewModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
            if let detail = item.detail, !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Text("\(item.roomName) · \(item.botName) · as of \(item.asOf.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
