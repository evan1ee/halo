import HaloApplication
import HaloDomain
import HaloFoundation
import Observation

/// Drives the sign-in flow from `SessionCoordinator` (docs/features/AUTHENTICATION.md). No logic
/// beyond mapping coordinator state to what the screens show.
@MainActor @Observable
public final class AuthViewModel {
    public enum Screen: Equatable {
        case launching
        case server
        case credentials(host: String)
        case busy
        /// The stored session couldn't be restored for a reason that may pass; the user can retry.
        case restoreFailed
        case signedIn
        case softLoggedOut
    }

    public private(set) var screen: Screen = .launching
    /// A short, user-facing explanation of the last failure; `nil` if there is none.
    public private(set) var errorMessage: String?
    public private(set) var userLabel: String?

    public var server = ""
    public var username = ""
    public var password = ""

    private let coordinator: SessionCoordinator
    private var observation: Task<Void, Never>?

    public init(coordinator: SessionCoordinator) {
        self.coordinator = coordinator
    }

    isolated deinit { observation?.cancel() }

    /// Starts observing and restores a stored session. Call once when the root view appears.
    public func start() async {
        if observation == nil {
            let states = await coordinator.states()
            observation = Task { [weak self] in
                for await state in states { self?.apply(state) }
            }
        }
        await coordinator.start()
    }

    public func submitServer() async { await coordinator.discover(server: server) }

    public func submitCredentials() async {
        let secret = password
        password = ""
        await coordinator.loginPassword(username: username, password: secret)
    }

    public func retryRestore() async { await coordinator.retryRestore() }
    public func signOut() async { await coordinator.logout() }

    func apply(_ state: SessionCoordinator.State) {
        switch state {
        case .launching, .restoring:
            screen = .launching
            errorMessage = nil
        case .signedOut(let failure):
            screen = .server
            errorMessage = failure.map(AuthMessages.text)
        case .discovering, .authenticating, .signingOut:
            screen = .busy
            errorMessage = nil  // a new attempt starts without the previous attempt's error
        case .choosingMethod(let details, let failure):
            screen = .credentials(host: details.homeserverURL.host() ?? "")
            errorMessage = failure.map(AuthMessages.text)
        case .restoreFailed(let failure):
            screen = .restoreFailed
            errorMessage = AuthMessages.text(failure)
        case .ready(let user):
            screen = .signedIn
            errorMessage = nil
            userLabel = user.rawValue
        case .softLoggedOut:
            screen = .softLoggedOut
        }
    }
}

/// User-facing text per error code. Never includes server text (ERROR_HANDLING).
enum AuthMessages {
    static func text(_ error: HaloError) -> String {
        switch error {
        case .unauthorized: "Wrong username or password, or the session expired."
        case .network: "Can't reach the server. Check the connection and try again."
        case .notFound: "No Matrix homeserver found at that address."
        case .invalidInput: "Check the entered address."
        case .unsupported("NO_SLIDING_SYNC"): "This server doesn't support the sync Halo needs."
        case .unsupported: "This server doesn't offer a sign-in method Halo supports."
        case .storage(.unavailable): "Secure storage isn't available yet. Unlock the device and try again."
        default: "Something went wrong (\(error.code))."
        }
    }
}
