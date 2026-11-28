#if canImport(SwiftUI)
import HaloDesignSystem
import SwiftUI

/// "What's New" sheet shown once per marketing version (ROADMAP M15, SR-05).
public struct WhatsNewView: View {
    private let version: String
    private let onContinue: () -> Void

    public init(version: String, onContinue: @escaping () -> Void) {
        self.version = version
        self.onContinue = onContinue
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HaloSpacing.l) {
                    VStack(alignment: .leading, spacing: HaloSpacing.xs) {
                        Text("What's New in Halo")
                            .font(.largeTitle.bold())
                        Text("Version \(version)")
                            .font(HaloTypography.meta)
                            .foregroundStyle(HaloColor.textSecondary)
                    }
                    .padding(.top, HaloSpacing.m)

                    featureRow(
                        symbol: "bell.badge",
                        title: "Honest unread badges",
                        detail: "Your badge and unread counts reflect what you've actually read across devices, with built-in diagnostics."
                    )
                    featureRow(
                        symbol: "bubble.left.and.bubble.right",
                        title: "Native iOS navigation & gestures",
                        detail: "Search chats and messages in one place, swipe to reply or mark read, and double-tap to react."
                    )
                    featureRow(
                        symbol: "checklist",
                        title: "Stickers & bot cards",
                        detail: "Browse custom sticker packs and act on structured bot checklists right in the timeline."
                    )
                    featureRow(
                        symbol: "ladybug",
                        title: "Beta feedback",
                        detail: "On TestFlight, take a screenshot to send feedback directly, or use Settings → Send feedback to share an optional diagnostics archive."
                    )
                }
                .padding(.horizontal, HaloSpacing.xl)
                .padding(.bottom, HaloSpacing.xl)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onContinue) {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, HaloSpacing.xl)
                .padding(.vertical, HaloSpacing.m)
                .haloBarBackground()
            }
        }
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: HaloSpacing.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(HaloColor.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HaloSpacing.xxs) {
                Text(title).font(HaloTypography.bodyEmphasis)
                Text(detail)
                    .font(HaloTypography.meta)
                    .foregroundStyle(HaloColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// In-app feedback sheet with optional, opt-in diagnostics archive attachment (M15, SR-05, PRIVACY §1).
struct FeedbackSheetView: View {
    let version: String
    let build: String
    let exportDiagnosticsZip: (@Sendable () async -> URL?)?
    @Environment(\.dismiss) private var dismiss
    @State private var diagnosticsURL: URL?
    @State private var preparingZip = false
    @State private var zipError = false

    private var feedbackSummary: String {
        "Halo \(version) (\(build)) feedback:\n\n"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Share feedback or a bug report. Diagnostics are never attached automatically — tap below only if you want to include a redacted diagnostics archive.")
                        .font(HaloTypography.meta)
                        .foregroundStyle(HaloColor.textSecondary)
                }
                Section("Optional diagnostics") {
                    if let url = diagnosticsURL {
                        ShareLink(item: url, subject: Text("Halo \(version) (\(build)) feedback")) {
                            Label("Share feedback with diagnostics (.zip)", systemImage: "square.and.arrow.up")
                        }
                        Button("Remove diagnostics attachment", role: .destructive) {
                            diagnosticsURL = nil
                        }
                    } else if let exportDiagnosticsZip {
                        Button {
                            preparingZip = true
                            zipError = false
                            Task {
                                let url = await exportDiagnosticsZip()
                                preparingZip = false
                                if let url {
                                    diagnosticsURL = url
                                } else {
                                    zipError = true
                                }
                            }
                        } label: {
                            HStack {
                                Label("Prepare diagnostics (.zip)", systemImage: "doc.zipper")
                                Spacer()
                                if preparingZip { ProgressView() }
                            }
                        }
                        .disabled(preparingZip)
                        if zipError {
                            Text("Couldn't prepare diagnostics archive. You can still share feedback without it.")
                                .font(HaloTypography.caption)
                                .foregroundStyle(HaloColor.danger)
                        }
                    }
                }
                Section {
                    ShareLink(item: feedbackSummary, subject: Text("Halo \(version) (\(build)) feedback")) {
                        Label("Share feedback text", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
