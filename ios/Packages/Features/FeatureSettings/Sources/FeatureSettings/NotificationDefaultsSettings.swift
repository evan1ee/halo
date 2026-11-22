import HaloDesignSystem
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

public enum NotificationMentionTarget: Sendable, CaseIterable, Identifiable {
    case user, room
    public var id: Self { self }
    var title: String { self == .user ? "Mentions of my name" : "@room mentions" }
}

public struct NotificationDefaultsActions: Sendable {
    /// Whether the mention rule is on, or `nil` when it couldn't be read.
    public let loadMention: @Sendable (NotificationMentionTarget) async -> Bool?
    /// `false` when the change failed.
    public let saveMention: @Sendable (NotificationMentionTarget, Bool) async -> Bool

    /// The current choice, or `nil` when the server couldn't be read (or the default is something Halo doesn't offer, e.g. muted).
    public let load: @Sendable (NotificationDefaultTarget) async -> NotificationDefaultChoice?
    /// `false` when the change failed.
    public let save: @Sendable (NotificationDefaultTarget, NotificationDefaultChoice) async -> Bool

    public init(
        load: @escaping @Sendable (NotificationDefaultTarget) async -> NotificationDefaultChoice?,
        save: @escaping @Sendable (NotificationDefaultTarget, NotificationDefaultChoice) async -> Bool,
        loadMention: @escaping @Sendable (NotificationMentionTarget) async -> Bool? = { _ in nil },
        saveMention: @escaping @Sendable (NotificationMentionTarget, Bool) async -> Bool = { _, _ in false }
    ) {
        self.loadMention = loadMention
        self.saveMention = saveMention
        self.load = load
        self.save = save
    }
}

@MainActor @Observable
public final class NotificationDefaultsModel {
    public private(set) var choices: [NotificationDefaultTarget: NotificationDefaultChoice] = [:]
    public private(set) var mentions: [NotificationMentionTarget: Bool] = [:]
    public private(set) var loaded = false
    public private(set) var error: String?
    private let actions: NotificationDefaultsActions

    public init(actions: NotificationDefaultsActions) { self.actions = actions }

    public func load() async {
        for target in NotificationDefaultTarget.allCases {
            if let choice = await actions.load(target) { choices[target] = choice }
        }
        for target in NotificationMentionTarget.allCases {
            if let enabled = await actions.loadMention(target) { mentions[target] = enabled }
        }
        loaded = true
    }

    /// Switches a mention rule; on failure the old value stays shown and the error says so.
    public func setMention(_ target: NotificationMentionTarget, enabled: Bool) async {
        guard mentions[target] != enabled else { return }
        error = nil
        if await actions.saveMention(target, enabled) {
            mentions[target] = enabled
        } else {
            error = "The setting couldn't be saved. Check your connection and try again."
        }
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
            ForEach(NotificationMentionTarget.allCases) { target in
                if let enabled = model.mentions[target] {
                    Toggle(target.title, isOn: Binding(get: { enabled }, set: { value in Task { await model.setMention(target, enabled: value) } }))
                }
            }
            if let message = model.error { Text(message).font(HaloTypography.meta).foregroundStyle(HaloColor.danger) }
        } header: {
            Text("Rooms and mentions")
        } footer: {
            Text("The defaults apply to rooms where you haven't chosen a setting of your own. All of these are kept on your account, so your other apps follow them.")
        }
        .task { await model.load() }
    }
}
