import HaloDesignSystem
import Observation
import SwiftUI

/// What Settings → Stickers → "Sticker packs" needs from the app (SETTINGS §3). Pack identity stays opaque to the screen.
public struct StickerPackSettingsActions: Sendable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let detail: String
        public init(id: String, name: String, detail: String) { self.id = id; self.name = name; self.detail = detail }
    }

    /// The packs the user enabled and can remove.
    public let load: @Sendable () async -> [Row]
    /// Takes one pack out of the user's list; `false` when the server call failed.
    public let remove: @Sendable (String) async -> Bool

    public init(load: @escaping @Sendable () async -> [Row], remove: @escaping @Sendable (String) async -> Bool) {
        self.load = load
        self.remove = remove
    }
}

@MainActor @Observable
public final class StickerPackSettingsModel {
    public private(set) var rows: [StickerPackSettingsActions.Row] = []
    public private(set) var loaded = false
    public private(set) var error: String?
    private let actions: StickerPackSettingsActions

    public init(actions: StickerPackSettingsActions) { self.actions = actions }

    public func load() async {
        rows = await actions.load()
        loaded = true
    }

    /// Removes a pack; on failure the row stays and the error says so.
    public func remove(_ id: String) async {
        error = nil
        if await actions.remove(id) {
            await load()
        } else {
            error = "The pack couldn't be removed. Check your connection and try again."
        }
    }
}

public struct StickerPackSettingsView: View {
    @State private var model: StickerPackSettingsModel

    public init(actions: StickerPackSettingsActions) { _model = State(initialValue: StickerPackSettingsModel(actions: actions)) }

    public var body: some View {
        Group {
            if !model.loaded {
                LoadingState(.rows(count: 3))
                    .padding(.horizontal, HaloSpacing.l)
            } else if model.rows.isEmpty, model.error == nil {
                EmptyState(
                    icon: "face.smiling",
                    title: "No packs added",
                    message: "Sticker packs you enable appear here."
                )
            } else {
                List {
                    if let error = model.error {
                        Section {
                            ErrorState(layout: .inline, title: "Couldn't remove pack", message: error)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        ForEach(model.rows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) { Task { await model.remove(row.id) } }
                            }
                        }
                    } footer: {
                        Text("Removing a pack only takes it out of your list. The room that holds it and its stickers are not touched.")
                    }
                }
            }
        }
        .navigationTitle("Sticker packs")
        .task { await model.load() }
    }
}
