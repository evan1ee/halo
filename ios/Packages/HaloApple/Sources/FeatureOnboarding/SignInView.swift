#if canImport(SwiftUI)
import HaloDesignSystem
import SwiftUI

/// The screens of the sign-in flow; the root view shows the signed-in content itself.
public struct SignInView: View {
    private enum Field { case server, username, password }
    @Bindable private var model: AuthViewModel
    @FocusState private var focus: Field?
    @State private var showingHomeserverHelp = false

    public init(model: AuthViewModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(spacing: HaloSpacing.l) {
                Spacer(minLength: HaloSpacing.xl)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(HaloColor.accent)
                    .accessibilityHidden(true)
                Text("Halo").font(.largeTitle.bold())
                switch model.screen {
                case .launching, .busy:
                    ProgressView().padding(.top, 8)
                case .server:
                    Text("Fast, private Matrix messaging with an honest unread badge.")
                        .font(HaloTypography.meta).foregroundStyle(HaloColor.textSecondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Homeserver", text: $model.server)
                        .plainInput(.URL)
                        .font(HaloTypography.body)
                        .padding(HaloSpacing.m)
                        .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
                        .focused($focus, equals: .server)
                        .submitLabel(.continue)
                        .onSubmit { if model.canSubmitServer { Task { await model.submitServer() } } }
                        .accessibilityLabel("Homeserver or Matrix ID")
                        .accessibilityHint("For example, matrix.org")
                    DisclosureGroup("What's a homeserver?", isExpanded: $showingHomeserverHelp) {
                        Text("Matrix works like email: your account lives on a homeserver (the part after the colon in @you:example.org). Enter that domain to sign in.")
                            .font(HaloTypography.caption)
                            .foregroundStyle(HaloColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, HaloSpacing.xs)
                    }
                    .font(HaloTypography.meta)
                    Button { Task { await model.submitServer() } } label: { Text("Continue").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.canSubmitServer)
            case .credentials(let host, let supportsPassword, let supportsOIDC):
                Text("Sign in to \(host)").font(.subheadline).foregroundStyle(.secondary)
                if supportsOIDC {
                    Button { Task { await model.signInWithOIDC() } } label: {
                        Label("Continue with browser", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("oidc-sign-in")
                    if supportsPassword {
                        Divider().padding(.vertical, 4)
                    }
                }
                if supportsPassword {
                    TextField("Username", text: $model.username)
                        .plainInput(.username)
                        .font(HaloTypography.body)
                        .padding(HaloSpacing.m)
                        .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $model.password)
                        .plainInput(.password)
                        .font(HaloTypography.body)
                        .padding(HaloSpacing.m)
                        .background(HaloColor.bgSecondary, in: RoundedRectangle(cornerRadius: HaloRadius.medium, style: .continuous))
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if model.canSubmitCredentials { Task { await model.submitCredentials() } } }
                    Button { Task { await model.submitCredentials() } } label: { Text("Sign in").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.canSubmitCredentials)
                }
                Button("Change server") { Task { await model.changeServer() } }
            case .restoreFailed:
                if model.storeIsDamaged {
                    // AC-REL-5: a way out that says what it costs, instead of a retry that can't work.
                    Text("Halo's saved data on this phone is damaged.")
                        .font(.headline).multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: HaloSpacing.s) {
                        Label("Signing out and in again fixes it. Your account and your messages on the server are not touched.", systemImage: "checkmark.circle")
                        Label("Lost on this phone: drafts and anything not yet sent.", systemImage: "square.and.pencil")
                        Label("Older encrypted messages need your recovery key, or another signed-in device, to read again.", systemImage: "key")
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    Button(role: .destructive) { Task { await model.signOut() } } label: { Text("Sign out and start again").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("damaged-store-sign-out")
                    Button("Try again") { Task { await model.retryRestore() } }
                } else {
                    Text("Your saved session couldn't be restored.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { Task { await model.retryRestore() } } label: { Text("Try again").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                }
            case .softLoggedOut:
                Text("Your session expired. Sign in again to continue.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Task { await model.signOut() } } label: { Text("Sign in again").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            case .signedIn:
                EmptyView()
            }
            if let message = model.errorMessage {
                Text(message).foregroundStyle(HaloColor.danger).font(HaloTypography.meta).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: HaloSpacing.l)
            }
            .padding(.horizontal, HaloSpacing.xl)
            .frame(maxWidth: 520)  // a readable column on iPad (M16, D91)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: model.screen, initial: true) { _, screen in
            switch screen {
            case .server: focus = .server
            case .credentials(_, let supportsPassword, _): focus = supportsPassword ? .username : nil
            default: focus = nil
            }
        }
    }
}

private enum InputKind { case URL, username, password }

private extension View {
    /// No auto-capitalisation or autocorrection; autofill hint. iOS only (the package also builds on macOS for tests).
    @ViewBuilder func plainInput(_ kind: InputKind) -> some View {
        #if os(iOS)
        switch kind {
        case .URL: textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.URL)
        case .username: textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
        case .password: textContentType(.password)
        }
        #else
        self
        #endif
    }
}
#endif
