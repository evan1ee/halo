import HaloDomain
import SwiftUI

/// The profile sheet of a person. All logic lives in `UserProfileViewModel`.
public struct UserProfileView: View {
    @State private var model: UserProfileViewModel
    @Environment(\.dismiss) private var dismiss

    public init(model: UserProfileViewModel) { _model = State(initialValue: model) }

    public var body: some View {
        NavigationStack {
            Group {
                switch model.content {
                case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let text): ContentUnavailableView("Couldn't load the profile", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(text))
                case .loaded(let profile, let ignored): list(profile, ignored: ignored)
                }
            }
            .navigationTitle("Profile")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await model.load() }
    }

    private func list(_ profile: UserProfile, ignored: Bool) -> some View {
        List {
            Section {
                // The user ID always shows under the name: a display name alone can impersonate (USER_PROFILES §10).
                Text(profile.displayName?.isEmpty == false ? profile.displayName! : "No display name").font(.headline)
                Text(profile.userID.rawValue).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Copy user ID") { copy(profile.userID.rawValue) }
            }
            if !model.isMe {
                Section {
                    Button("Message") { Task { await model.message() } }.accessibilityIdentifier("messageUser")
                    Button(ignored ? "Unignore" : "Ignore", role: ignored ? nil : .destructive) { Task { await model.toggleIgnore() } }
                        .accessibilityIdentifier("ignoreUser")
                } footer: {
                    Text(ignored ? "You don't see this person's messages." : "Ignoring hides this person's messages and invitations everywhere.")
                }
            }
            if let error = model.actionError { Section { Text(error).foregroundStyle(.red) } }
        }
        .disabled(model.isWorking)
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
