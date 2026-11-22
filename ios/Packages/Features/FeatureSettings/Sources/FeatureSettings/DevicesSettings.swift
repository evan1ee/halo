import Foundation
import HaloDesignSystem
import Observation
import SwiftUI

/// What Settings → Account → Sessions needs from the app (SETTINGS §3). Read-only: signing other sessions out needs interactive
/// authentication and is not built.
public struct DevicesSettingsActions: Sendable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let lastSeen: Date?
        public let isCurrent: Bool
        public init(id: String, name: String, lastSeen: Date?, isCurrent: Bool) {
            self.id = id
            self.name = name
            self.lastSeen = lastSeen
            self.isCurrent = isCurrent
        }
    }

    /// The account's sessions, or `nil` when they couldn't be read.
    public let load: @Sendable () async -> [Row]?

    public init(load: @escaping @Sendable () async -> [Row]?) { self.load = load }
}

@MainActor @Observable
public final class DevicesSettingsModel {
    public private(set) var rows: [DevicesSettingsActions.Row] = []
    public private(set) var loaded = false
    public private(set) var error: String?
    private let actions: DevicesSettingsActions

    public init(actions: DevicesSettingsActions) { self.actions = actions }

    /// Reads the list; on failure what was shown stays and the error says so.
    public func load() async {
        if let rows = await actions.load() {
            self.rows = rows
            error = nil
        } else {
            error = "The sessions couldn't be loaded. Check your connection and try again."
        }
        loaded = true
    }

    /// "Active now" for the current device, otherwise when the homeserver last heard from the session.
    func detail(_ row: DevicesSettingsActions.Row, now: Date = .now) -> String {
        if row.isCurrent { return "This device" }
        guard let lastSeen = row.lastSeen else { return "Last active unknown" }
        return "Last active " + lastSeen.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(Locale(identifier: "en_US")))
    }
}

struct DevicesSettingsView: View {
    @State private var model: DevicesSettingsModel

    init(actions: DevicesSettingsActions) { _model = State(initialValue: DevicesSettingsModel(actions: actions)) }

    var body: some View {
        List {
            if let error = model.error {
                Section { Text(error).foregroundStyle(HaloColor.danger) }
            }
            Section {
                if model.loaded, model.rows.isEmpty, model.error == nil {
                    Text("No sessions").foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(model.detail(row)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Every place this account is signed in. To sign a session out, use another Matrix app for now.")
            }
        }
        .navigationTitle("Sessions")
        .refreshable { await model.load() }
        .task { await model.load() }
    }
}
