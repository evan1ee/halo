import Foundation
import HaloFoundation

/// A static location to send from the attachment panel's Location tab (docs/features/COMPOSER_PANELS.md §7, D100): an
/// `m.location` message with a `geo:` URI, end-to-end encrypted in encrypted rooms like any message.
public struct OutgoingLocation: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    /// Metres; `nil` for a pin the user placed.
    public let accuracy: Double?
    /// `true` for the user's own position, `false` for a dropped pin.
    public let isOwnLocation: Bool
    /// Optional human-readable place name (e.g. when forwarding a named location).
    public let description: String?

    public init(latitude: Double, longitude: Double, accuracy: Double? = nil, description: String? = nil, isOwnLocation: Bool) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.description = description
        self.isOwnLocation = isOwnLocation
    }

    /// RFC 5870 `geo:` URI, 6 decimals (about 10 cm), with `;u=` uncertainty when known.
    public var geoURI: String {
        var uri = "geo:" + Self.coordinate(latitude) + "," + Self.coordinate(longitude)
        if let accuracy, accuracy > 0 { uri += ";u=" + String(Int(accuracy.rounded())) }
        return uri
    }

    /// The fallback text other clients show.
    public var body: String {
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return (isOwnLocation ? "Location" : "Pinned location") + ": " + Self.coordinate(latitude) + ", " + Self.coordinate(longitude)
    }

    public func validate() throws(HaloError) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { throw .invalidInput("LOCATION_OUT_OF_RANGE") }
    }

    static func coordinate(_ value: Double) -> String {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        var text = String(format: "%.6f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

/// A poll to start from the attachment panel's Poll tab (D100): `m.poll.start` (MSC3381, as the SDK sends it).
public struct OutgoingPoll: Sendable, Equatable {
    public static let maximumAnswers = 20
    public static let maximumLength = 340

    public let question: String
    public let answers: [String]
    /// Voters may pick every answer they like (otherwise one).
    public let allowsMultipleAnswers: Bool
    /// Results are shown only when the poll ends (`undisclosed`).
    public let hidesResultsUntilEnd: Bool

    /// Trims the question and answers and drops blank answers.
    public init(question: String, answers: [String], allowsMultipleAnswers: Bool = false, hidesResultsUntilEnd: Bool = false) {
        self.question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        self.answers = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.allowsMultipleAnswers = allowsMultipleAnswers
        self.hidesResultsUntilEnd = hidesResultsUntilEnd
    }

    /// How many answers a voter may pick.
    public var maxSelections: Int { allowsMultipleAnswers ? answers.count : 1 }

    /// A question, 2–20 distinct answers, each within the length limit.
    public func validate() throws(HaloError) {
        guard !question.isEmpty else { throw .invalidInput("POLL_NO_QUESTION") }
        guard answers.count >= 2 else { throw .invalidInput("POLL_TOO_FEW_ANSWERS") }
        guard answers.count <= Self.maximumAnswers else { throw .invalidInput("POLL_TOO_MANY_ANSWERS") }
        guard Set(answers.map { $0.lowercased() }).count == answers.count else { throw .invalidInput("POLL_DUPLICATE_ANSWERS") }
        guard question.count <= Self.maximumLength, answers.allSatisfy({ $0.count <= Self.maximumLength })
        else { throw .invalidInput("POLL_TOO_LONG") }
    }

    public var isValid: Bool { (try? validate()) != nil }
}
