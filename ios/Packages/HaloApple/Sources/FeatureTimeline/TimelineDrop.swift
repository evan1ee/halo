#if canImport(SwiftUI)
import HaloDomain
import SwiftUI
import UniformTypeIdentifiers

/// What a dragged item becomes when it is dropped on a conversation (M16, iPad drag and drop).
enum DropKind: Equatable {
    /// A picture: joins the composer's pending photos, like one picked from the library.
    case photo
    /// Any other file: sent at once, like one chosen with the file importer.
    case file
    /// Text or a link: appended to what is being typed.
    case text
}

/// Decides a dropped item's kind from its type identifiers. Pure.
enum DropClassifier {
    /// The types a conversation accepts, in the order they are tried.
    static let acceptedTypes: [UTType] = [.image, .fileURL, .data, .url, .plainText]

    static func kind(for identifiers: [String]) -> DropKind? {
        let types = identifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .image) }) { return .photo }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .file }
        if types.contains(where: { $0.conforms(to: .url) || $0.conforms(to: .plainText) }) { return .text }
        if types.contains(where: { $0.conforms(to: .data) }) { return .file }
        return nil
    }
}

/// Makes a conversation a drop target (iPad drag and drop from Photos, Files, Safari or another Halo window).
struct TimelineDropModifier: ViewModifier {
    let model: TimelineViewModel
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: DropClassifier.acceptedTypes, isTargeted: $targeted) { providers in
                handle(providers)
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 3)
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private func handle(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for (index, provider) in providers.enumerated() {
            guard let kind = DropClassifier.kind(for: provider.registeredTypeIdentifiers) else { continue }
            accepted = true
            switch kind {
            case .photo:
                load(provider, type: .image) { data, name in
                    await model.attachPhotos([(data: data, filename: name ?? "photo-\(index + 1)")])
                }
            case .file:
                load(provider, type: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? .fileURL : .data) { data, name in
                    let type = name.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
                    await model.sendFile(data: data, filename: name ?? "file", mimeType: type?.preferredMIMEType ?? "application/octet-stream")
                }
            case .text:
                let type: UTType = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? .url : .plainText
                provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
                    let text: String? = switch item {
                    case let url as URL: url.absoluteString
                    case let text as String: text
                    case let data as Data: String(data: data, encoding: .utf8)
                    default: nil
                    }
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in
                        model.draft += (model.draft.isEmpty || model.draft.hasSuffix(" ") || model.draft.hasSuffix("\n") ? "" : " ") + text
                    }
                }
            }
        }
        return accepted
    }

    /// Reads the dropped file (refusing a huge one before loading it) and hands its bytes and name on.
    private func load(_ provider: NSItemProvider, type: UTType, _ deliver: @escaping @Sendable (Data, String?) async -> Void) {
        _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
            guard let url else { return }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= OutgoingFile.maximumBytes else {
                Task { @MainActor in model.reportFileTooLarge() }
                return
            }
            // The system's temporary file disappears when this closure returns, so it is read here.
            guard let data = try? Data(contentsOf: url) else {
                Task { @MainActor in model.reportFileUnreadable() }
                return
            }
            let name = url.lastPathComponent
            Task { await deliver(data, name) }
        }
    }
}
#endif
