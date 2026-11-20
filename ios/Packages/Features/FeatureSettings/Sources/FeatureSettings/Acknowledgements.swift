import Foundation

/// One third-party component and its licence (docs/security/LICENSE_COMPLIANCE.md; D39).
public struct Acknowledgement: Sendable, Equatable, Identifiable {
    public let name: String
    public let version: String
    public let license: String
    public let repository: String
    public var id: String { name + " " + version }
}

/// The acknowledgements list, generated from the licence inventory of the SDK build (`scripts/rust-license-inventory.py`),
/// which is bundled as `acknowledgements.csv` and compared with `docs/security/inventory` by a test (AC-SET-1).
public enum Acknowledgements {
    /// Parses the inventory CSV (header `crate,version,license,repository,…`; quoted fields allowed). Malformed lines are skipped.
    public static func parse(_ csv: String) -> [Acknowledgement] {
        csv.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = split(String(line))
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return Acknowledgement(name: fields[0], version: fields[1], license: fields[2], repository: fields.count > 3 ? fields[3] : "")
        }
    }

    /// Entries whose name or licence contains `query` (case-insensitive); all of them for a blank query.
    public static func filter(_ entries: [Acknowledgement], query: String) -> [Acknowledgement] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(needle) || $0.license.localizedCaseInsensitiveContains(needle) }
    }

    /// The bundled list.
    public static func bundled() -> [Acknowledgement] {
        guard let url = Bundle.module.url(forResource: "acknowledgements", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    private static func split(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        for character in line {
            switch character {
            case "\"": quoted.toggle()
            case "," where !quoted: fields.append(current); current = ""
            default: current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
