import HaloDomain
import HaloFoundation
import HaloPlatform
import UIKit
import UserNotifications
import UniformTypeIdentifiers

/// The system share sheet's "Halo" target (M16). It only stages what was shared into the App Group inbox
/// (`FileShareInbox`); the app asks which chat to send it to when it next opens. The extension has no session, never
/// talks to the homeserver and never starts sync (AGENTS §17).
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
        var failure: String?
        var notified = false
        do {
            var staged: [FileShareInbox.Staged] = []
            for provider in providers {
                if let item = try await ShareItemReader.read(provider) { staged.append(item) }
            }
            try inbox.stage(staged)
            notified = await Self.notifyReady()
        } catch {
            failure = Self.message(for: error)
        }
        spinner.stopAnimating()
        finish(failure: failure, notified: notified)
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

    private static func notifyReady() async -> Bool {
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
        return (try? await center.add(request)) != nil
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
