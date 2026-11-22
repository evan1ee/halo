/// Matrix identifiers as validated value types (docs/data/DATA_MODELS.md §1).
///
/// Privacy (docs/security/SECURITY.md §6): `description` and `debugDescription` never contain the
/// raw identifier, so string interpolation into a log line can't leak it. Use `rawValue` only
/// where the identifier is sent to the SDK or stored.

/// The Matrix limit for user, room and event identifiers, in UTF-8 bytes.
let maximumIdentifierLength = 255

/// `@localpart:server.name`
public struct UserID: MatrixIdentifier {
    public let rawValue: String

    public init(_ rawValue: String) throws(HaloError) {
        try Self.validate(rawValue, sigil: "@", requiresServerName: true, kind: "USER_ID")
        self.rawValue = rawValue
    }
}

/// `!opaque_id` or `!opaque_id:server.name`. The server-name part isn't required: not every room
/// version includes one.
public struct RoomID: MatrixIdentifier {
    public let rawValue: String

    public init(_ rawValue: String) throws(HaloError) {
        try Self.validate(rawValue, sigil: "!", requiresServerName: false, kind: "ROOM_ID")
        self.rawValue = rawValue
    }
}

/// `$opaque_id`
public struct EventID: MatrixIdentifier {
    public let rawValue: String

    public init(_ rawValue: String) throws(HaloError) {
        try Self.validate(rawValue, sigil: "$", requiresServerName: false, kind: "EVENT_ID")
        self.rawValue = rawValue
    }
}

/// A device identifier (no sigil).
public struct DeviceID: MatrixIdentifier {
    public let rawValue: String

    public init(_ rawValue: String) throws(HaloError) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= maximumIdentifierLength else {
            throw .invalidInput("DEVICE_ID_LENGTH")
        }
        self.rawValue = rawValue
    }
}

/// The account a store or a session belongs to (docs/architecture/SYSTEM_DESIGN.md §4).
public typealias AccountID = UserID

public protocol MatrixIdentifier: Hashable, Sendable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    var rawValue: String { get }
    init(_ rawValue: String) throws(HaloError)
}

extension MatrixIdentifier {
    public var description: String { "\(Self.self)(<redacted>)" }
    public var debugDescription: String { description }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.code))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func validate(_ raw: String, sigil: Character, requiresServerName: Bool, kind: String) throws(HaloError) {
        guard raw.first == sigil else { throw .invalidInput("\(kind)_SIGIL") }
        guard raw.utf8.count <= maximumIdentifierLength else { throw .invalidInput("\(kind)_LENGTH") }
        let body = raw.dropFirst()
        guard !body.isEmpty, !body.contains(where: \.isWhitespace) else { throw .invalidInput("\(kind)_BODY") }
        if requiresServerName {
            guard let colon = body.firstIndex(of: ":"), colon != body.startIndex,
                  body.index(after: colon) != body.endIndex
            else { throw .invalidInput("\(kind)_SERVER_NAME") }
        }
    }
}
