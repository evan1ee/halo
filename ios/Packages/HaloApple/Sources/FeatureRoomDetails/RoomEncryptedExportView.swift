#if canImport(SwiftUI)
import HaloDesignSystem
import HaloDomain
import SwiftUI

/// On-demand passphrase-encrypted room history export screen (D32, R-P2-EXPORT).
public struct RoomEncryptedExportView: View {
    private let model: RoomDetailsViewModel
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var result: RoomDetailsViewModel.EncryptedRoomExportResult?

    public init(model: RoomDetailsViewModel) { self.model = model }

    private var canSubmit: Bool {
        passphrase.count >= 8 && passphrase == confirmPassphrase && !model.isExportingRoom
    }

    public var body: some View {
        Form {
            Section {
                SecureField("Passphrase (min. 8 characters)", text: $passphrase)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("export-passphrase")
                SecureField("Confirm passphrase", text: $confirmPassphrase)
                    .textContentType(.newPassword)
                    .accessibilityIdentifier("export-passphrase-confirm")
            } header: {
                Text("Encryption passphrase")
            } footer: {
                Text("The archive is encrypted on-device with AES-256-GCM (PBKDF2-HMAC-SHA256). Keep this passphrase safe — it is never stored.")
            }

            if !confirmPassphrase.isEmpty && passphrase != confirmPassphrase {
                Section {
                    Text("Passphrases do not match.")
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.danger)
                }
            }

            if let error = model.roomExportError {
                Section {
                    Text(error)
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.danger)
                }
            }

            Section {
                Button {
                    result = nil
                    Task {
                        result = await model.exportEncryptedRoom(passphrase: passphrase)
                    }
                } label: {
                    HStack {
                        if model.isExportingRoom {
                            ProgressView()
                            Text("Encrypting…")
                        } else {
                            Label("Create encrypted export", systemImage: "lock.doc")
                        }
                    }
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("create-encrypted-export")
            }

            if let result {
                Section("Export ready") {
                    Text(result.messageCount == 1
                        ? "1 message encrypted into \(result.url.lastPathComponent)."
                        : "\(result.messageCount) messages encrypted into \(result.url.lastPathComponent).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ShareLink(item: result.url) {
                        Label("Save or Share Export", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-encrypted-export")
                }
            }
        }
        .navigationTitle("Encrypted Export")
    }
}
#endif
