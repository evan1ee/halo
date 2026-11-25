import FeatureRoomList
import HaloApplication
import HaloDomain
import HaloFoundation
import HaloMatrixAdapter
import HaloPlatform
import SwiftUI
import UIKit
import UserNotifications
import UniformTypeIdentifiers

/// The system share sheet's "Halo" target (M16, D87, D92). It stages what was shared into the App Group inbox
/// (`FileShareInbox`) first, so nothing is lost, then offers the chats from the SDK's local store and sends to the one the
/// person picks, waiting for the server before it closes. It never starts sync (AGENTS §17). Without a session, or when
/// the store can't be read, it falls back to leaving the items for Halo and a notification that opens it.
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = String(localized: "Saving to Halo…")
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        Task { await stageAndFinish() }
    }

    private func stageAndFinish() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let inbox = FileShareInbox(directory: HaloShared.shareInboxDirectory())
        let payload: SharePayload
        do {
            var staged: [FileShareInbox.Staged] = []
            for provider in providers {
                if let item = try await ShareItemReader.read(provider) { staged.append(item) }
            }
            payload = try inbox.stage(staged)
        } catch {
            spinner.stopAnimating()
            finish(failure: Self.message(for: error), notified: false)
            return
        }
        do {
            let targets = try await openTargets(inbox: inbox)
            spinner.stopAnimating()
            show(targets: targets, payload: payload, inbox: inbox)
        } catch {
            // No session, or the store isn't readable: Halo sends it when the person opens it.
            let notified = await Self.notifyReady()
            spinner.stopAnimating()
            finish(failure: nil, notified: notified)
        }
    }

    /// The SDK session, restored from the Keychain exactly as the notification extension does; kept for sending.
    private var coordinator: ShareCoordinator?

    private func openTargets(inbox: FileShareInbox) async throws -> [ShareTargetPickerView.Target] {
        let keychain = HaloShared.keychain()
        guard let data = try await keychain.read(.session) else { throw HaloError.unauthorized(soft: false) }
        let stored = try JSONDecoder().decode(StoredSession.self, from: data)
        let session = MatrixSessionPort(
            baseDirectory: HaloShared.storeDirectory(),
            holderName: "share",
            sendsMessages: false,
            lightweightRuntime: true,
            enablesSlidingSync: false,
            readStoredSession: {
                (try? keychain.readSync(.session)).flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
            },
            persistRefreshedSession: { refreshed in
                if let encoded = try? JSONEncoder().encode(refreshed) { try? keychain.writeSync(encoded, for: .session) }
            })
        try await session.restore(stored)
        let targets = try await MatrixShareTargetPort(session: session).targets()
        guard !targets.isEmpty else { throw HaloError.notFound }
        coordinator = ShareCoordinator(inbox: inbox, timelines: MatrixTimelinePort(session: session))
        return targets.map { ShareTargetPickerView.Target(id: $0.id, name: $0.name) }
    }

    private func show(targets: [ShareTargetPickerView.Target], payload: SharePayload, inbox: FileShareInbox) {
        guard let coordinator else { return }
        let model = ShareHandoffViewModel(coordinator: coordinator, confirmingFor: .seconds(90)) { [weak self] _ in
            self?.complete()
        }
        model.present(payload)
        let root = ShareRootView(model: model, targets: targets, onLater: { [weak self] in
            Task { @MainActor in
                _ = await Self.notifyReady()
                self?.complete()
            }
        }, onDiscarded: { [weak self] in self?.complete() })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private var completed = false

    private func complete() {
        guard !completed else { return }
        completed = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func finish(failure: String?, notified: Bool) {
        let title = failure == nil ? String(localized: "Saved to Halo") : String(localized: "Couldn't share")
        let text = failure ?? (notified
            ? String(localized: "Tap the notification to choose a chat to send it to.")
            : String(localized: "Open Halo to choose a chat to send it to."))
        label.text = title
        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default) { [weak self] _ in
            if failure == nil {
                self?.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        })
        present(alert, animated: true)
    }

    /// An extension can't open its app, so a local notification is the way back: tapping it opens Halo, which then offers
    /// the chat picker. Only when notifications are already allowed (the extension never asks), and with no content.
    static let readyNotificationID = "halo.share.ready"

    static func notifyReady() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return false
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Ready to send in Halo")
        content.body = String(localized: "Tap to choose a chat.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: readyNotificationID, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        return (try? await center.add(request)) != nil  // best-effort: the system decides whether the reminder shows; the share itself is already done
    }

    private static func message(for error: HaloError) -> String {
        switch error {
        case .invalidInput("SHARE_TOO_LARGE"): String(localized: "That is too large to send. The limit is 50 MB.")
        case .invalidInput("SHARE_EMPTY"): String(localized: "Halo can share text, links, photos and files.")
        default: String(localized: "Something went wrong. Try again.")
        }
    }
}

/// Reads one `NSItemProvider` into the inbox's `Staged` form. Photos and files are copied while the system's temporary
/// file exists.
@MainActor
enum ShareItemReader {
    static func read(_ provider: NSItemProvider) async throws(HaloError) -> FileShareInbox.Staged? {
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return try await file(provider, type: .image, isImage: true)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await file(provider, type: .fileURL, isImage: false)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await string(provider, type: .url).map { .url($0) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return await string(provider, type: .plainText).map { .text($0) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
            return try await file(provider, type: .data, isImage: false)
        }
        return nil
    }

    /// Text and links arrive as `String`, `URL` or `Data`, depending on the sending app.
    private static func string(_ provider: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                let value: String? = switch item {
                case let url as URL: url.absoluteString
                case let text as String: text
                case let data as Data: String(data: data, encoding: .utf8)
                default: nil
                }
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed?.isEmpty == false ? trimmed : nil)
            }
        }
    }

    private static func file(_ provider: NSItemProvider, type: UTType, isImage: Bool) async throws(HaloError) -> FileShareInbox.Staged? {
        let result: Result<FileShareInbox.Staged?, HaloError> = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: .success(nil))
                    return
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= FileShareInbox.maximumPayloadBytes else {
                    continuation.resume(returning: .failure(.invalidInput("SHARE_TOO_LARGE")))
                    return
                }
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: .success(nil))
                    return
                }
                let contentType = UTType(filenameExtension: url.pathExtension)
                let mime = contentType?.preferredMIMEType ?? (isImage ? "image/jpeg" : "application/octet-stream")
                continuation.resume(returning: .success(.file(
                    data: data, filename: url.lastPathComponent, mimeType: mime,
                    isImage: isImage || contentType?.conforms(to: .image) == true
                )))
            }
        }
        return try result.get()
    }
}

/// The picker, closing the extension once the model has nothing left to send (sent or discarded).
private struct ShareRootView: View {
    let model: ShareHandoffViewModel
    let targets: [ShareTargetPickerView.Target]
    let onLater: () -> Void
    let onDiscarded: () -> Void

    var body: some View {
        ShareTargetPickerView(model: model, targets: targets, onLater: onLater)
            .onChange(of: model.current) { _, payload in
                if payload == nil { onDiscarded() }
            }
    }
}
