import Foundation
import HaloFoundation

/// Parsed destination of a `matrix.to` permalink or `matrix:` URI (docs/design/NAVIGATION.md §3).
public enum MatrixLink: Sendable, Equatable {
    case room(RoomID, event: EventID?)
    case roomAlias(String, event: EventID?)
    case user(UserID)

    /// Parses `https://matrix.to/#/...` and `matrix:...` URIs; returns `nil` for unrelated or malformed URLs.
    public static func parse(_ url: URL) -> MatrixLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" || scheme == "http" {
            guard url.host?.lowercased() == "matrix.to" else { return nil }
            guard let fragment = url.fragment, !fragment.isEmpty else { return nil }
            return parseMatrixToFragment(fragment)
        }
        if scheme == "matrix" {
            return parseMatrixURI(url)
        }
        return nil
    }

    private static func parseMatrixToFragment(_ fragment: String) -> MatrixLink? {
        // Strip query params inside the fragment (`?via=...`) and leading slashes.
        let pathPart = fragment.split(separator: "?", maxSplits: 1).first.map(String.init) ?? fragment
        let segments = pathPart
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }
        guard let first = segments.first, !first.isEmpty else { return nil }
        let second = segments.count > 1 ? segments[1] : nil

        if first.hasPrefix("@"), let user = try? UserID(first) {
            return .user(user)
        }
        if first.hasPrefix("!"), let room = try? RoomID(first) {
            let event = second.flatMap { try? EventID($0) }
            return .room(room, event: event)
        }
        if first.hasPrefix("#"), isValidAlias(first) {
            let event = second.flatMap { try? EventID($0) }
            return .roomAlias(first, event: event)
        }
        return nil
    }

    private static func parseMatrixURI(_ url: URL) -> MatrixLink? {
        // Format per MSC2312: matrix:u/local:server, matrix:r/alias:server[/e/event], matrix:roomid/id:server[/e/event]
        let raw = url.absoluteString
        guard let colonIdx = raw.firstIndex(of: ":") else { return nil }
        var rest = String(raw[raw.index(after: colonIdx)...])
        while rest.hasPrefix("/") { rest.removeFirst() }
        let pathPart = rest.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rest
        let segments = pathPart
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { String($0).removingPercentEncoding }
        guard segments.count >= 2 else { return nil }

        let event: EventID? = {
            if segments.count >= 4, segments[2].lowercased() == "e" {
                let rawID = segments[3].hasPrefix("$") ? segments[3] : "$\(segments[3])"
                return try? EventID(rawID)
            }
            return nil
        }()

        switch segments[0].lowercased() {
        case "u":
            let rawID = segments[1].hasPrefix("@") ? segments[1] : "@\(segments[1])"
            return (try? UserID(rawID)).map(MatrixLink.user)
        case "roomid":
            let rawID = segments[1].hasPrefix("!") ? segments[1] : "!\(segments[1])"
            return (try? RoomID(rawID)).map { .room($0, event: event) }
        case "r":
            let rawAlias = segments[1].hasPrefix("#") ? segments[1] : "#\(segments[1])"
            return isValidAlias(rawAlias) ? .roomAlias(rawAlias, event: event) : nil
        default:
            return nil
        }
    }

    private static func isValidAlias(_ alias: String) -> Bool {
        guard alias.hasPrefix("#"),
              !alias.contains(where: \.isWhitespace),
              let colon = alias.firstIndex(of: ":"),
              alias.distance(from: alias.startIndex, to: colon) > 1
        else { return false }
        return !alias[alias.index(after: colon)...].isEmpty
    }
}
