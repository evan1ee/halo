#if canImport(AuthenticationServices)
import AuthenticationServices
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Presents an OIDC / OAuth 2.0 authorization URL in `ASWebAuthenticationSession` and returns the redirect callback URL
/// (or `nil` if the user cancels) (AUTHENTICATION FR-3).
@MainActor
public final class WebAuthSessionPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?

    public override init() { super.init() }

    public func authenticate(url: URL, callbackScheme: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, _ in
                Task { @MainActor in
                    self?.activeSession = nil
                    continuation.resume(returning: callbackURL)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            if !session.start() {
                activeSession = nil
                continuation.resume(returning: nil)
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        var firstScene: UIWindowScene?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if firstScene == nil { firstScene = windowScene }
            if let window = windowScene.keyWindow {
                return window
            }
        }
        if let firstScene {
            return ASPresentationAnchor(windowScene: firstScene)
        }
        return ASPresentationAnchor(frame: .zero)
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
