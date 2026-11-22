import AppIntents
import Foundation
import HaloApplication
import HaloDomain
import HaloFoundation

/// "Send a message to <chat> in Halo" (M16, builds on D88).
/// Uses the same opt-in `ChatEntity` list as `OpenChatIntent`; asks for confirmation before sending so Siri never sends
/// accidentally, and speaks honestly whether the message was confirmed or queued (AGENTS.md §4.4).
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"
    static let description = IntentDescription("Sends a message to a chat in Halo.")
    static let openAppWhenRun = false

    @Parameter(title: "Chat") var chat: ChatEntity
    @Parameter(title: "Message") var message: String

    @Dependency private var sender: SiriSendCoordinatorBox

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$chat)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SiriSendError.message("The message is empty.")
        }
        guard let room = try? RoomID(chat.id) else {
            throw SiriSendError.message("That chat is no longer available.")
        }
        try await requestConfirmation(result: .result(dialog: "Send \"\(trimmed)\" to \(chat.name)?"))
        do {
            let outcome = try await sender.value.send(text: trimmed, to: room)
            switch outcome {
            case .confirmed:
                return .result(dialog: "Sent to \(chat.name).")
            case .queued:
                return .result(dialog: "Queued for \(chat.name). It will finish sending when Halo connects.")
            }
        } catch {
            throw SiriSendError.message(HaloErrorCopy.message(for: error))
        }
    }
}

/// Wraps `SiriSendCoordinator` for `AppDependencyManager`.
final class SiriSendCoordinatorBox: Sendable {
    let value: SiriSendCoordinator
    init(_ value: SiriSendCoordinator) { self.value = value }
}

private enum SiriSendError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): "\(text)"
        }
    }
}
