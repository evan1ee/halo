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
    private var activeAnchor: ASPresentationAnchor?

    public override init() { super.init() }

    public func authenticate(url: URL, callbackScheme: String) async -> URL? {
        // The sheet needs a window to sit on; with no window scene (nothing on screen) there is nothing to sign in from.
        guard let anchor = Self.currentAnchor() else { return nil }
        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, _ in
                Task { @MainActor in
                    self?.activeSession = nil
                    self?.activeAnchor = nil
                    continuation.resume(returning: callbackURL)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session
            activeAnchor = anchor
            if !session.start() {
                activeSession = nil
                activeAnchor = nil
                continuation.resume(returning: nil)
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // `authenticate` only starts a session after it found an anchor, so this is set whenever the system asks.
        guard let anchor = activeAnchor ?? Self.currentAnchor() else {
            preconditionFailure("ASWebAuthenticationSession asked for an anchor with no window scene")
        }
        return anchor
    }

    /// The key window of a connected scene, else a new window on the first scene (`UIWindow(frame:)` is deprecated in iOS 26).
    private static func currentAnchor() -> ASPresentationAnchor? {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.lazy.compactMap(\.keyWindow).first { return window }
        return scenes.first.map { ASPresentationAnchor(windowScene: $0) }
        #else
        return ASPresentationAnchor()
        #endif
    }
}
#endif
