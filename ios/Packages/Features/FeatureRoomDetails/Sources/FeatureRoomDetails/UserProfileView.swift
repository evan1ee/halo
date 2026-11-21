import HaloDesignSystem
import HaloDomain
import SwiftUI

/// The profile sheet of a person. All logic lives in `UserProfileViewModel`.
public struct UserProfileView: View {
    @State private var model: UserProfileViewModel
    @State private var avatar: Data?
    @State private var copied = false
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
        .task { avatar = await model.avatarData() }
    }

    private func list(_ profile: UserProfile, ignored: Bool) -> some View {
        let name = profile.displayName?.isEmpty == false ? profile.displayName! : "No display name"
        let initialSeed = profile.displayName?.isEmpty == false ? profile.displayName! : profile.userID.rawValue
        return List {
            Section {
                VStack(spacing: 8) {
                    AvatarCircle(name: initialSeed, imageData: avatar, size: 80)
                    // The user ID always shows under the name: a display name alone can impersonate (USER_PROFILES §10).
                    Text(name).font(.title3.bold()).multilineTextAlignment(.center)
                    Text(profile.userID.rawValue).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                Button {
                    copy(profile.userID.rawValue)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy user ID", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                if let url = model.shareURL {
                    ShareLink(item: url) {
                        Label("Share profile link", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("shareUserLink")
                }
            }
            if !model.isMe {
                Section {
                    Button { Task { await model.message() } } label: {
                        Label("Message", systemImage: "bubble.left")
                    }
                    .accessibilityIdentifier("messageUser")
                    Button(role: ignored ? nil : .destructive) { Task { await model.toggleIgnore() } } label: {
                        Label(ignored ? "Unignore" : "Ignore", systemImage: ignored ? "hand.raised.slash" : "hand.raised")
                    }
                    .accessibilityIdentifier("ignoreUser")
                } footer: {
                    Text(ignored ? "You don't see this person's messages." : "Ignoring hides this person's messages and invitations everywhere.")
                }
            }
            if let error = model.actionError { Section { Text(error).foregroundStyle(.red) } }
        }
        .disabled(model.isWorking)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
