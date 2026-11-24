#if canImport(SwiftUI)
import Foundation
import HaloDomain
import SwiftUI
import UniformTypeIdentifiers

/// Extracts draggable payloads from a timeline row (M16, iPad drag and drop out of a conversation). Pure.
enum TimelineDragExtractor {
    /// Returns the plain text to drag from a row, or `nil` for non-text / system rows.
    static func text(for row: TimelineRow) -> String? {
        switch row.style {
        case .message, .ownMessage, .notice, .emote:
            break
        case .placeholder, .state, .divider, .marker:
            return nil
        }
        guard row.file == nil, !row.isSticker else { return nil }
        guard let body = row.source?.body ?? (row.showsText ? row.text : nil) else { return nil }
        return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : body
    }

    static func allowsPhotoDrag(isSticker: Bool, hasImageData: Bool) -> Bool {
        !isSticker && hasImageData
    }

    static func allowsFileDrag(size: Int?) -> Bool {
        guard let size else { return true }
        return size <= TimelineViewModel.openSizeLimit
    }
}

/// Transfers a downloaded timeline file attachment out of Halo (to Files, Mail, Notes, or another Halo window).
struct DraggedTimelineFile: Transferable, Sendable {
    let filename: String
    let load: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            let url = try await item.load()
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
    }
}

/// Attaches `.draggable(text)` on iPad when a row has draggable text (on iPhone, `UIDragInteraction` intercepts long-press actions).
struct OptionalTextDragModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        if let text, UIDevice.current.userInterfaceIdiom == .pad {
            content.draggable(text)
        } else {
            content
        }
        #else
        if let text {
            content.draggable(text)
        } else {
            content
        }
        #endif
    }
}
#endif
