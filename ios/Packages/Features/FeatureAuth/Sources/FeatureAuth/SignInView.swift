#if canImport(SwiftUI)
import SwiftUI

/// The screens of the sign-in flow; the root view shows the signed-in content itself.
public struct SignInView: View {
    @Bindable private var model: AuthViewModel

    public init(model: AuthViewModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 16) {
            switch model.screen {
            case .launching, .busy:
                ProgressView()
            case .server:
                TextField("Server (example.org)", text: $model.server)
                    .plainInput(.URL).textFieldStyle(.roundedBorder)
                Button("Continue") { Task { await model.submitServer() } }
                    .buttonStyle(.borderedProminent)
            case .credentials(let host):
                Text("Sign in to \(host)").font(.headline)
                TextField("Username", text: $model.username)
                    .plainInput(.username).textFieldStyle(.roundedBorder)
                SecureField("Password", text: $model.password)
                    .plainInput(.password).textFieldStyle(.roundedBorder)
                Button("Sign in") { Task { await model.submitCredentials() } }
                    .buttonStyle(.borderedProminent)
            case .restoreFailed:
                Button("Try again") { Task { await model.retryRestore() } }.buttonStyle(.borderedProminent)
            case .softLoggedOut, .signedIn:
                EmptyView()
            }
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).font(.footnote).multilineTextAlignment(.center)
            }
        }
        .padding()
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
