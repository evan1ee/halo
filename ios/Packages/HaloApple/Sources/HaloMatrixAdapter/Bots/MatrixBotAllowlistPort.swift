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
            guard let json = try await client.accountData(eventType: BotAllowlist.eventType) else { return nil }
            return BotAllowlist.fromAccountData(Data(json.utf8))
        } catch { throw ErrorMapper.map(error) }
    }

    public func save(_ allowlist: BotAllowlist) async throws(HaloError) {
        let client = try await session.signedInClient()
        do {
            // Never overwrite data this version can't read (a newer Halo wrote it).
            if let existing = try await client.accountData(eventType: BotAllowlist.eventType),
               BotAllowlist.fromAccountData(Data(existing.utf8)) == nil,
               (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) != nil {
                throw HaloError.unsupported("BOT_ALLOWLIST_NEWER_VERSION")
            }
            let content = String(decoding: allowlist.accountData(), as: UTF8.self)
            try await client.setAccountData(eventType: BotAllowlist.eventType, content: content)
        } catch let error as HaloError { throw error } catch { throw ErrorMapper.map(error) }
    }
}
