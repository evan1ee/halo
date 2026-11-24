import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloPersistence
import HaloPlatform

/// Account session lifecycle, GRDB attachment, foreground transitions, and debug exports (ADR-0022 step 2).
extension AppRoot {
    /// Opens Halo's database for each signed-in account and restores the read intents and drafts it holds. When the
    /// account changes or signs out, everything kept in memory for the previous one is dropped first.
    func followReadIntents() async {
        var current: UserID?
        for await state in await sessionCoordinator.states() {
            switch state {
            case .ready(let user):
                guard user != current else { continue }
                if current != nil { await resetAccountState() }
                current = user
                signedInUser = user
                do {
                    let directory = HaloShared.storeDirectory().appendingPathComponent("halo", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let dbPath = directory.appendingPathComponent("halo.sqlite").path
                    let database = try HaloDatabase(path: dbPath)
                    let signal = DarwinSignal()
                    let recordStore = NotificationRecordStore(
                        database: database, account: user,
                        onChange: { signal.post() }, externalChanges: { signal.observe() }
                    )
                    #if DEBUG
                    Self.exportDeviceDiagnostics(databasePath: dbPath, database: database, recordCount: recordStore.all().count)
                    #endif
                    activeRecords.current = recordStore
                    await readState.attach(records: recordStore)
                    await receipts.restore(from: ReadIntentStore(database: database, account: user))
                    await drafts.attach(DraftStore(database: database, account: user))
                    await klipy.attach(KlipyShelfStore(account: user))
                    await botActivity.attach(BotTaskStore(database: database, account: user))
                    #if DEBUG
                    let log = log
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    auditPort = AuditEventStore(database: database, account: user)
                    await readState.setAudit(.init(port: AuditEventStore(database: database, account: user), roomHash: { log.id($0) }, appVersion: version))
                    #else
                    if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
                        let log = log
                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                        auditPort = AuditEventStore(database: database, account: user)
                        await readState.setAudit(.init(port: AuditEventStore(database: database, account: user), roomHash: { log.id($0) }, appVersion: version))
                    }
                    #endif
                } catch {
                    // Without a database, receipts and drafts still work from memory; there is nothing to restore.
                }
                await syncBotAllowlist()
            case .signedOut:
                guard current != nil else { continue }
                current = nil
                signedInUser = nil
                await resetAccountState()
            default:
                continue
            }
        }
    }

    func resetAccountState() async {
        await receipts.reset()
        await readState.setAudit(nil)
        auditPort = nil
        await readState.reset()
        await readState.attach(records: nil)
        activeRecords.current = nil
        await drafts.reset()
        await botActivity.reset()
        await stickers.reset()
        await klipy.reset()
        await timelinePort.dropWarm()
        searchPort.reset()
        preferences.botSenders = []
    }

    /// Updates foreground state for sync, read-state auditing, and the shared App Group flag checked by the NSE (R-08).
    func setForeground(_ active: Bool) async {
        attentionCache.setForeground(active)
        await sync.setForeground(active)
        await readState.setForeground(active)
    }

    #if DEBUG
    static func exportNSEMetrics(namespace: String) {
        let fileManager = FileManager.default
        guard let group = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.\(namespace)") else { return }
        let source = group.appendingPathComponent("nse-metrics.jsonl")
        let target = URL.documentsDirectory.appendingPathComponent("nse-metrics.jsonl")
        try? fileManager.removeItem(at: target)
        try? fileManager.copyItem(at: source, to: target)
    }

    static func exportDeviceDiagnostics(databasePath: String, database: HaloDatabase, recordCount: Int) {
        let fm = FileManager.default
        let dir = (databasePath as NSString).deletingLastPathComponent
        func protection(_ path: String) -> String {
            guard fm.fileExists(atPath: path) else { return "missing" }
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.protectionKey] as? FileProtectionType)?.rawValue ?? "none"
        }
        let lines = [
            "at=\(ISO8601DateFormatter().string(from: Date()))",
            "sqliteVersion=\((try? database.sqliteVersion()) ?? "error")",
            "dirProtection=\(protection(dir))",
            "dbProtection=\(protection(databasePath))",
            "walProtection=\(protection(databasePath + "-wal"))",
            "shmProtection=\(protection(databasePath + "-shm"))",
            "notificationRecordsAtLaunch=\(recordCount)",
        ]
        let out = URL.documentsDirectory.appendingPathComponent("device-diagnostics.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    }
    #endif

    static var minimumLogLevel: LogLevel {
        #if DEBUG
        .debug
        #else
        .info
        #endif
    }

    /// A random per-install value for hashing identifiers in logs (SECURITY §6).
    static func installSalt() -> UInt64 {
        let key = "logSalt"
        if let stored = UserDefaults.standard.object(forKey: key) as? UInt64 { return stored }
        let salt = UInt64.random(in: .min ... .max)
        UserDefaults.standard.set(salt, forKey: key)
        return salt
    }
}
