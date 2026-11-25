import Foundation
import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `BotAllowlistPort` over Matrix account data `one.mbm.halo.bot_allowlist` (DATA_MODELS, SETTINGS §3).
public final class MatrixBotAllowlistPort: BotAllowlistPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func load() async throws(HaloError) -> BotAllowlist? {
        let client = try await session.signedInClient()
        do {
            return try await ServerAccountData(client).storedOrServer(BotAllowlist.eventType, client).flatMap(BotAllowlist.fromAccountData)
        } catch { throw ErrorMapper.map(error) }
    }

    public func change(from old: BotAllowlist, to new: BotAllowlist) async throws(HaloError) -> BotAllowlist {
        let client = try await session.signedInClient()
        var result = new
        do {
            try await ServerAccountData(client).update(BotAllowlist.eventType) { content in
                guard let content else { return new.content(replacing: nil) }
                // Never overwrite data this version can't read (a newer Halo wrote it).
                guard let current = BotAllowlist.fromContent(content) else { throw HaloError.unsupported("BOT_ALLOWLIST_NEWER_VERSION") }
                result = current.applying(from: old, to: new)
                return result == current ? nil : result.content(replacing: content)
            }
            return result
        } catch { throw ErrorMapper.map(error) }
    }
}
