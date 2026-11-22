#if canImport(SwiftUI)
import HaloDesignSystem
import SwiftUI

/// The screens of the sign-in flow; the root view shows the signed-in content itself.
public struct SignInView: View {
    private enum Field { case server, username, password }
    @Bindable private var model: AuthViewModel
    @FocusState private var focus: Field?

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
                    Text("Enter your Matrix homeserver to sign in.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                TextField("Server (example.org)", text: $model.server)
                    .plainInput(.URL).textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .server)
                    .submitLabel(.continue)
                    .onSubmit { if model.canSubmitServer { Task { await model.submitServer() } } }
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
                        .plainInput(.username).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $model.password)
                        .plainInput(.password).textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if model.canSubmitCredentials { Task { await model.submitCredentials() } } }
                    Button { Task { await model.submitCredentials() } } label: { Text("Sign in").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.canSubmitCredentials)
                }
                Button("Change server") { Task { await model.changeServer() } }
            case .restoreFailed:
                Text("Your saved session couldn't be restored.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { Task { await model.retryRestore() } } label: { Text("Try again").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Sign out", role: .destructive) { Task { await model.signOut() } }
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
