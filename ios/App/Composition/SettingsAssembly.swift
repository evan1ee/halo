import FeatureAuth
import FeatureProfile
import FeatureSettings
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloPlatform
import SwiftUI
import UIKit

/// Settings model factory, diagnostics export, storage, and account-action adapters (ADR-0022 step 2, TD-10).
extension AppRoot {
    /// Builds the `SettingsConfiguration` for `SettingsView` (TD-10: replaces the 25-closure view initializer).
    func makeSettingsConfiguration(onOpenStickers: @escaping @MainActor () -> Void) -> SettingsConfiguration {
        SettingsConfiguration(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            onPrivateReceiptsChange: { [weak self] value in
                guard let self else { return }
                self.preferences.privateReceipts = value
                Task { await self.receipts.setPrivateReceipts(value) }
            },
            onPreferencesChanged: { [weak self] in
                self?.preferences.reload()
            },
            saveBotSenders: { [weak self] senders in
                guard let self else { return false }
                return await self.saveBotSenders(senders)
            },
            loadMediaPreviews: { [weak self] in
                guard let self else { return .always }
                return await self.mediaPreviewChoice()
            },
            saveMediaPreviews: { [weak self] choice in
                guard let self else { return false }
                return await self.setMediaPreviewChoice(choice)
            },
            makeProfileView: { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(ProfileSettingsView(actions: self.profileSettings()))
            },
            stickerPacks: stickerPackSettings(),
            onOpenStickers: onOpenStickers,
            devices: deviceSettings(),
            changePassword: changePasswordActions(),
            verifyDevice: VerifyDeviceAction(
                isNeeded: { [weak self] in self?.recovery.needsRecovery ?? false },
                makeView: { [weak self] in
                    guard let self else { return AnyView(EmptyView()) }
                    return AnyView(RecoveryView(model: self.recovery))
                }
            ),
            diagnostics: { [weak self] in
                guard let self else { return "" }
                return await self.diagnosticsReport()
            },
            exportDiagnosticsZip: { [weak self] in
                guard let self else { return nil }
                return await self.exportDiagnosticsZip()
            },
            reconcile: { [weak self] in
                await self?.reconcileNow()
            },
            unexplainedAuditCount: { [weak self] in
                await self?.unexplainedAuditCount()
            },
            storageSizes: { [weak self] in
                guard let self else { return [] }
                return await self.storageSizes()
            },
            clearCache: { [weak self] in
                guard let self else { return false }
                return await self.clearMediaCache()
            },
            security: { [weak self] in
                guard let self else { return [] }
                return [
                    StorageSize(name: "This device", text: self.recovery.deviceStatus),
                    StorageSize(name: "Recovery key", text: self.recovery.recoveryStatus),
                ]
            },
            setUpRecovery: { [weak self] in
                guard let self else { return .failure(SettingsMessage("Unavailable")) }
                switch await self.recovery.setUpRecovery() {
                case .success(let key): return .success(key)
                case .failure(let failure): return .failure(SettingsMessage(failure.text, offersReplace: failure.backupExists))
                }
            },
            replaceRecovery: { [weak self] in
                guard let self else { return .failure(SettingsMessage("Unavailable")) }
                switch await self.recovery.replaceRecovery() {
                case .success(let key): return .success(key)
                case .failure(let failure): return .failure(SettingsMessage(failure.text))
                }
            },
            notificationDefaults: notificationDefaults(),
            notificationStatus: { [weak self] in
                guard let self else { return "Unknown" }
                return await self.notificationStatus()
            },
            openSystemSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            },
            onSignOut: { [weak self] in
                guard let self else { return }
                Task { await self.auth.signOut() }
            }
        )
    }

    func diagnosticsReport() async -> String {
        let info = Bundle.main.infoDictionary
        var lines = [
            "Halo \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        lines.append("Bot messages shown as plain text (no template matched), this launch: \(unrecognisedBots.count)")
        if let auditPort {
            let events = (try? await auditPort.all().count).map(String.init) ?? "unavailable"
            let unexplained = (try? await auditPort.unexplainedCount()).map(String.init) ?? "unavailable"
            lines.append("Read-state audit: \(events) events, \(unexplained) unexplained")
        } else {
            lines.append("Read-state audit: off in this build")
        }
        return lines.joined(separator: "\n")
    }

    func exportDiagnosticsZip() async -> URL? {
        let reportText = await diagnosticsReport()
        let logLines = ringLog.snapshot().joined(separator: "\n") + "\n"
        var auditLines: [String] = []
        if let events = try? await auditPort?.all() {
            let formatter = ISO8601DateFormatter()
            for event in events {
                auditLines.append(
                    "{\"at\":\"\(formatter.string(from: event.at))\",\"room_hash\":\"\(event.roomHash)\",\"kind\":\"\(event.finding.kind.rawValue)\",\"reason\":\"\(event.finding.reason)\",\"app_version\":\"\(event.appVersion)\",\"inputs\":\(event.inputsJSON)}"
                )
            }
        }
        let auditJSONL = auditLines.isEmpty ? "" : (auditLines.joined(separator: "\n") + "\n")

        let log = self.log
        let rooms = await roomCoordinator.rooms
        var currentStates: [RoomID: RoomReadState] = [:]
        for await snapshot in await readState.states() {
            currentStates = snapshot
            break
        }
        var roomLines: [String] = []
        for summary in rooms {
            let roomHash = log.id(summary.id)
            let state = currentStates[summary.id]
            let c = summary.read
            let mode = switch c.mode { case .allMessages: "all"; case .mentionsAndKeywords: "mentions"; case .mute: "mute" }
            let reasons = (state?.reasons.map { $0.rawValue } ?? []).joined(separator: ",")
            roomLines.append(
                "{\"room_hash\":\"\(roomHash)\",\"membership\":\"\(summary.membership)\",\"enc\":\(summary.isEncrypted),\"mode\":\"\(mode)\",\"marked\":\(c.isMarkedUnread),\"server\":[\(c.server.notification),\(c.server.highlight)],\"sdk\":[\(c.sdk.unreadMessages),\(c.sdk.unreadNotifications),\(c.sdk.unreadMentions)],\"attention\":\(state?.attention ?? false),\"unread\":\(state?.hasUnread ?? false),\"badge\":\(state?.badgeCount ?? 0),\"reasons\":\"\(reasons)\"}"
            )
        }
        let roomsJSONL = roomLines.isEmpty ? "" : (roomLines.joined(separator: "\n") + "\n")

        let archive = DiagnosticsZipArchive.build([
            .init(filename: "report.txt", text: reportText + "\n"),
            .init(filename: "app-logs.txt", text: logLines),
            .init(filename: "audit-events.jsonl", text: auditJSONL),
            .init(filename: "room-snapshots.jsonl", text: roomsJSONL),
        ])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("halo-diagnostics.zip")
        do {
            try archive.write(to: out, options: .atomic)
            return out
        } catch {
            return nil
        }
    }

    func clearMediaCache() async -> Bool {
        await media.clearCache()
        let root = HaloShared.storeDirectory()
        let fm = FileManager.default
        if let subdirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for dir in subdirs where dir.lastPathComponent != "halo" {
                let cacheDir = dir.appendingPathComponent("caches", isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { continue }
                for file in files { try? fm.removeItem(at: file) }
            }
        }
        return true
    }

    func unexplainedAuditCount() async -> Int? {
        guard let auditPort else { return nil }
        return try? await auditPort.unexplainedCount()
    }

    func reconcileNow() async {
        await receipts.flush()
        await readState.reconcile()
    }

    nonisolated func storageSizes() async -> [StorageSize] {
        let directory = HaloShared.storeDirectory()
        func size(of url: URL) -> Int64 {
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
            var total: Int64 = 0
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
            return total
        }
        let own = size(of: directory.appendingPathComponent("halo", isDirectory: true))
        return [StorageSize(name: "Messages and keys", bytes: max(0, size(of: directory) - own)), StorageSize(name: "Halo database", bytes: own)]
    }

    func mediaPreviewChoice() async -> MediaPreviewChoice {
        switch await previewPolicy.setting() {
        case .always: .always
        case .privateRoomsOnly: .privateRoomsOnly
        case .never: .never
        }
    }

    func setMediaPreviewChoice(_ choice: MediaPreviewChoice) async -> Bool {
        let setting: MediaPreviewSetting = switch choice {
        case .always: .always
        case .privateRoomsOnly: .privateRoomsOnly
        case .never: .never
        }
        do { try await previewPolicy.setSetting(setting); return true } catch { return false }
    }

    func notificationDefaults() -> NotificationDefaultsActions {
        let port = notificationDefaultsPort
        @Sendable func kind(_ target: NotificationDefaultTarget) -> NotificationDefaultKind { target == .directChats ? .directChats : .groupChats }
        return NotificationDefaultsActions(
            load: { target in
                switch try? await port.mode(for: kind(target)) {
                case .allMessages: .allMessages
                case .mentionsAndKeywords: .mentionsAndKeywords
                case .mute, nil: nil
                }
            },
            save: { target, choice in
                do { try await port.setMode(choice == .allMessages ? .allMessages : .mentionsAndKeywords, for: kind(target)) } catch { return false }
                return true
            },
            loadMention: { target in try? await port.isMentionEnabled(target == .user ? .user : .room) },
            saveMention: { target, enabled in
                do { try await port.setMention(target == .user ? .user : .room, enabled: enabled) } catch { return false }
                return true
            }
        )
    }

    func changePasswordActions() -> ChangePasswordActions {
        let port = passwordPort
        return ChangePasswordActions(
            isAvailable: { await port.canChangePassword() },
            submit: { current, new in
                do throws(HaloError) { try await port.changePassword(current: current, new: new) } catch {
                    switch error {
                    case .invalidInput("CURRENT_PASSWORD"): return .wrongCurrent
                    case .invalidInput("NEW_PASSWORD"): return .refusedNew
                    default: return .failed
                    }
                }
                return .changed
            }
        )
    }

    func deviceSettings() -> DevicesSettingsActions {
        let port = devicesPort
        return DevicesSettingsActions(load: {
            guard let devices = try? await port.devices() else { return nil }
            return devices.map { .init(id: $0.id, name: $0.displayName ?? $0.id, lastSeen: $0.lastSeen, isCurrent: $0.isCurrent) }
        })
    }

    func stickerPackSettings() -> StickerPackSettingsActions {
        let library = stickers
        let separator = "\u{1F}"
        return StickerPackSettingsActions(
            load: {
                await library.load(currentRoom: nil)
                guard let snapshot = await library.snapshots().first(where: { _ in true }) else { return [] }
                return snapshot.packs.filter { $0.source == .userEnabled }.map { pack in
                    .init(
                        id: pack.ref.room.rawValue + separator + pack.ref.stateKey, name: pack.displayName,
                        detail: "\(pack.stickers.count) \(pack.stickers.count == 1 ? "sticker" : "stickers")"
                    )
                }
            },
            remove: { id in
                let parts = id.components(separatedBy: separator)
                guard parts.count == 2, let room = try? RoomID(parts[0]) else { return false }
                return await library.disablePack(PackRef(room: room, stateKey: parts[1]))
            }
        )
    }

    func profileSettings() -> ProfileSettingsActions {
        let port = profilePort
        let media = media
        let rooms = roomCoordinator
        return ProfileSettingsActions(
            loadName: { try? await port.ownDisplayName() },
            saveName: { name in (try? await port.setOwnDisplayName(name)) != nil },
            loadIgnored: { (try? await port.ignoredUsers())?.map(\.rawValue) },
            unignore: { raw in
                guard let user = try? UserID(raw), (try? await port.unignore(user)) != nil else { return false }
                await rooms.refreshIgnoredUsers()
                return true
            },
            loadAvatar: {
                guard let ref = try? await port.ownAvatar() else { return nil }
                return try? await media.thumbnail(ref, width: 256, height: 256)
            },
            setAvatar: { data in
                guard let image = try? ImagePreparer(maximumDimension: 512).prepare(data: data, filename: "avatar") else { return false }
                return (try? await port.setOwnAvatar(mimeType: image.mimeType, data: image.data)) != nil
            },
            removeAvatar: { (try? await port.removeOwnAvatar()) != nil },
            userID: signedInUser?.rawValue
        )
    }
}
