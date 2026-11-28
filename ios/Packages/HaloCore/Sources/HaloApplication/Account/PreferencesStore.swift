import HaloDomain
import Observation

/// Observable store over `PreferencesPort` (TD-02, ADR-0022): the app's only reader and writer of device preferences.
///
/// Settings, the root view and every coordinator share one instance, so a change (bot allowlist, appearance, privacy blur,
/// receipt privacy) reaches the whole UI at once (audit F-05: no second store over the same keys).
@MainActor @Observable
public final class PreferencesStore {
    private let port: any PreferencesPort
    public private(set) var snapshot: PreferencesSnapshot

    public init(port: any PreferencesPort) {
        self.port = port
        self.snapshot = port.load()
    }

    public var privateReceipts: Bool {
        get { snapshot.privateReceipts }
        set { update { $0.privateReceipts = newValue } }
    }

    public var sendTypingNotices: Bool {
        get { snapshot.sendTypingNotices }
        set { update { $0.sendTypingNotices = newValue } }
    }

    public var privacyBlur: Bool {
        get { snapshot.privacyBlur }
        set { update { $0.privacyBlur = newValue } }
    }

    public var botSenders: [String] {
        get { snapshot.botSenders }
        set { update { $0.botSenders = newValue } }
    }

    public var appearance: AppAppearance {
        get { snapshot.appearance }
        set { update { $0.appearance = newValue } }
    }

    public var lastSeenWhatsNewVersion: String? {
        get { snapshot.lastSeenWhatsNewVersion }
        set { update { $0.lastSeenWhatsNewVersion = newValue } }
    }

    public var chatsInSystemSearch: Bool {
        get { snapshot.chatsInSystemSearch }
        set { update { $0.chatsInSystemSearch = newValue } }
    }

    public var followFocusFilter: Bool {
        get { snapshot.followFocusFilter }
        set { update { $0.followFocusFilter = newValue } }
    }

    public var searchHistoryPaused: Bool {
        get { snapshot.searchHistoryPaused }
        set { update { $0.searchHistoryPaused = newValue } }
    }

    public var searchHistoryOnMobileData: Bool {
        get { snapshot.searchHistoryOnMobileData }
        set { update { $0.searchHistoryOnMobileData = newValue } }
    }

    public var mediaCacheRetention: MediaCacheRetention {
        get { snapshot.mediaCacheRetention }
        set { update { $0.mediaCacheRetention = newValue } }
    }

    private func update(_ mutate: (inout PreferencesSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        snapshot = next
        port.save(next)
    }
}
