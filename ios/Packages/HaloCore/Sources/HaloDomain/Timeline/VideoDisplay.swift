import Foundation
import HaloFoundation

/// Prepares a local video file for sending: validates size, reads display-oriented dimensions (handling portrait
/// rotation) and duration, and generates a JPEG poster thumbnail (MEDIA_ATTACHMENTS FR-2, M20-3).
public protocol VideoPreparing: Sendable {
    func prepare(fileURL: URL, filename: String, mimeType: String) async throws(HaloError) -> OutgoingFile
}

/// Pure display, caption, and filename rules for timeline videos (MEDIA_ATTACHMENTS FR-2, M20-3).
public enum VideoDisplayMetrics {
    /// Default aspect ratio when the event announces no dimensions (standard 16:9 landscape).
    public static let defaultAspectRatio: Double = 16.0 / 9.0
    /// Keeps extreme aspect ratios within legible timeline bounds while faithfully distinguishing portrait (9:16 ≈ 0.56)
    /// and landscape (16:9 ≈ 1.78) videos.
    public static let minimumAspectRatio: Double = 0.55
    public static let maximumAspectRatio: Double = 2.2

    /// Returns the display aspect ratio (`width / height`), clamped for timeline layout, or `defaultAspectRatio`.
    public static func aspectRatio(width: Int?, height: Int?) -> Double {
        guard let width, let height, width > 0, height > 0 else { return defaultAspectRatio }
        let raw = Double(width) / Double(height)
        guard raw.isFinite, raw > 0 else { return defaultAspectRatio }
        return min(maximumAspectRatio, max(minimumAspectRatio, raw))
    }

    /// Resolves a human-visible caption from `caption` and `body`, suppressing bare filenames like `"clip.mp4"`.
    public static func caption(body: String, explicitCaption: String?) -> String? {
        if let explicit = explicitCaption?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeFilename(trimmed) else { return nil }
        return trimmed
    }

    /// Ensures a downloaded video file carries an extension `AVPlayer` recognises (default `.mp4` for `video/mp4`).
    public static func videoFilename(from rawName: String, mimeType: String?) -> String {
        let last = rawName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let base = last.isEmpty || last == "." || last == ".." ? "video" : last
        let existingExt = (base as NSString).pathExtension.lowercased()
        let knownVideoExtensions: Set<String> = ["mp4", "mov", "m4v", "3gp", "webm", "mkv", "avi"]
        if knownVideoExtensions.contains(existingExt) { return base }

        let mime = (mimeType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let inferredExt: String = switch mime {
        case "video/mp4", "video/mpeg4": "mp4"
        case "video/quicktime": "mov"
        case "video/x-m4v": "m4v"
        case "video/3gpp": "3gp"
        case "video/webm": "webm"
        default: "mp4"
        }
        return "\(base).\(inferredExt)"
    }

    private static func looksLikeFilename(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let dot = text.lastIndex(of: "."), dot != text.startIndex else { return false }
        let ext = text[text.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber } && ext.contains(where: \.isLetter)
    }
}
