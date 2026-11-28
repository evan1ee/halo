import Foundation
import HaloDesignSystem
import Observation
import SwiftUI

/// What Settings → Account → Sessions needs from the app (SETTINGS §3). Signing other sessions out asks for the password (UIA);
/// an OIDC account does it on its account page, so `canSignOut` is false there.
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

    /// Whether the app can sign other sessions out itself.
    public let canSignOut: @Sendable () async -> Bool
    /// Signs these sessions out; `nil` on success, otherwise what went wrong.
    public let signOut: @Sendable (_ ids: [String], _ password: String) async -> SignOutFailure?

    public enum SignOutFailure: Sendable, Equatable { case wrongPassword, failed }

    public init(
        load: @escaping @Sendable () async -> [Row]?,
        canSignOut: @escaping @Sendable () async -> Bool = { false },
        signOut: @escaping @Sendable (_ ids: [String], _ password: String) async -> SignOutFailure? = { _, _ in .failed }
    ) {
        self.load = load
        self.canSignOut = canSignOut
        self.signOut = signOut
    }
}

@MainActor @Observable
public final class DevicesSettingsModel {
    public private(set) var rows: [DevicesSettingsActions.Row] = []
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var canSignOut = false
    /// The sessions the person is about to sign out, until they confirm with the password or cancel.
    public var pendingSignOut: [String]?
    public private(set) var isSigningOut = false
    private let actions: DevicesSettingsActions

    public init(actions: DevicesSettingsActions) { self.actions = actions }

    /// The sessions other than this device.
    public var others: [DevicesSettingsActions.Row] { rows.filter { !$0.isCurrent } }

    /// Signs these sessions out (the alert has already closed). A wrong password asks again; success reloads the list.
    public func confirmSignOut(_ ids: [String], password: String) async {
        guard !ids.isEmpty, !password.isEmpty, !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        switch await actions.signOut(ids, password) {
        case nil:
            error = nil
            await load()
        case .wrongPassword?:
            error = "That password isn't right. Try again."
            pendingSignOut = ids
        case .failed?:
            error = "The sessions couldn't be signed out. Check your connection and try again."
        }
    }

    /// Reads the list; on failure what was shown stays and the error says so.
    public func load() async {
        if let rows = await actions.load() {
            self.rows = rows
            error = nil
        } else {
            error = "The sessions couldn't be loaded. Check your connection and try again."
        }
        canSignOut = await actions.canSignOut()
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
    @State private var password = ""

    init(actions: DevicesSettingsActions) { _model = State(initialValue: DevicesSettingsModel(actions: actions)) }

    var body: some View {
        Group {
            if !model.loaded {
                LoadingState(.rows(count: 3))
                    .padding(.horizontal, HaloSpacing.l)
            } else if model.rows.isEmpty, let error = model.error {
                ErrorState(title: "Couldn't load sessions", message: error) {
                    Task { await model.load() }
                }
            } else if model.rows.isEmpty {
                EmptyState(
                    icon: "iphone",
                    title: "No sessions",
                    message: "Active sessions for your account appear here."
                )
            } else {
                List {
                    if let error = model.error {
                        Section {
                            ErrorState(layout: .inline, title: "Couldn't update sessions", message: error) {
                                Task { await model.load() }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        ForEach(model.rows) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                Text(model.detail(row)).font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                if model.canSignOut, !row.isCurrent {
                                    Button("Sign out", role: .destructive) { model.pendingSignOut = [row.id] }
                                }
                            }
                        }
                    } footer: {
                        Text(model.canSignOut
                             ? "Every place this account is signed in. Swipe a session to sign it out."
                             : "Every place this account is signed in. To sign a session out, use your account page.")
                    }
                    if model.canSignOut, !model.others.isEmpty {
                        Section {
                            Button("Sign out all other sessions", role: .destructive) { model.pendingSignOut = model.others.map(\.id) }
                        }
                    }
                }
            }
        }
        .alert("Sign out \(model.pendingSignOut?.count == 1 ? "this session" : "these sessions")?", isPresented: Binding(
            get: { model.pendingSignOut != nil }, set: { if !$0 { model.pendingSignOut = nil; password = "" } })) {
            SecureField("Account password", text: $password)
            Button("Sign out", role: .destructive) {
                let typed = password, ids = model.pendingSignOut ?? []
                password = ""
                Task { await model.confirmSignOut(ids, password: typed) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll be signed out and their encrypted messages stay on this account. Enter your password to confirm.")
        }
        .navigationTitle("Sessions")
        .refreshable { await model.load() }
        .task { await model.load() }
    }
}
