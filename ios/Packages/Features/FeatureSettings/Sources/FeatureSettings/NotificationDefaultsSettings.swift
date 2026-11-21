import Observation
import SwiftUI

/// What Settings → Notifications → "Default for new rooms" needs from the app (SETTINGS §3). Muting everything by default is
/// not offered: it is a per-room choice.
public enum NotificationDefaultChoice: String, Sendable, CaseIterable, Identifiable {
    case allMessages, mentionsAndKeywords
    public var id: String { rawValue }
    var title: String { self == .allMessages ? "All messages" : "Mentions and keywords" }
}

public enum NotificationDefaultTarget: Sendable, CaseIterable, Identifiable {
    case directChats, groupChats
    public var id: Self { self }
    var title: String { self == .directChats ? "Direct chats" : "Group chats" }
}

public struct NotificationDefaultsActions: Sendable {
    /// The current choice, or `nil` when the server couldn't be read (or the default is something Halo doesn't offer, e.g. muted).
    public let load: @Sendable (NotificationDefaultTarget) async -> NotificationDefaultChoice?
    /// `false` when the change failed.
    public let save: @Sendable (NotificationDefaultTarget, NotificationDefaultChoice) async -> Bool

    public init(
        load: @escaping @Sendable (NotificationDefaultTarget) async -> NotificationDefaultChoice?,
        save: @escaping @Sendable (NotificationDefaultTarget, NotificationDefaultChoice) async -> Bool
    ) {
        self.load = load
        self.save = save
    }
}

@MainActor @Observable
public final class NotificationDefaultsModel {
    public private(set) var choices: [NotificationDefaultTarget: NotificationDefaultChoice] = [:]
    public private(set) var loaded = false
    public private(set) var error: String?
    private let actions: NotificationDefaultsActions

    public init(actions: NotificationDefaultsActions) { self.actions = actions }

    public func load() async {
        for target in NotificationDefaultTarget.allCases {
            if let choice = await actions.load(target) { choices[target] = choice }
        }
        loaded = true
    }

    /// Saves a change; on failure the old choice stays shown and the error says so.
    public func set(_ target: NotificationDefaultTarget, to choice: NotificationDefaultChoice) async {
        guard choices[target] != choice else { return }
        error = nil
        if await actions.save(target, choice) {
            choices[target] = choice
        } else {
            error = "The setting couldn't be saved. Check your connection and try again."
        }
    }
}

struct NotificationDefaultsSection: View {
    @State private var model: NotificationDefaultsModel

    init(actions: NotificationDefaultsActions) { _model = State(initialValue: NotificationDefaultsModel(actions: actions)) }

    var body: some View {
        Section {
            ForEach(NotificationDefaultTarget.allCases) { target in
                Picker(target.title, selection: Binding(
                    get: { model.choices[target] },
                    set: { if let choice = $0 { Task { await model.set(target, to: choice) } } })
                ) {
                    if model.choices[target] == nil { Text(model.loaded ? "Custom" : "…").tag(NotificationDefaultChoice?.none) }
                    ForEach(NotificationDefaultChoice.allCases) { Text($0.title).tag(NotificationDefaultChoice?.some($0)) }
                }
            }
            if let message = model.error { Text(message).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Default for rooms")
        } footer: {
            Text("Used for rooms where you haven't chosen a setting of your own. Shared with your other apps through your account.")
        }
        .task { await model.load() }
    }
}
