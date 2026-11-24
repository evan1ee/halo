#if canImport(SwiftUI)
import SwiftUI

/// The search field at the top of a panel: a rounded field with a magnifier and a clear button.
public struct PanelSearchField: View {
    @Binding var text: String
    let placeholder: String
    let identifier: String

    public init(text: Binding<String>, placeholder: String, identifier: String) {
        _text = text
        self.placeholder = placeholder
        self.identifier = identifier
    }

    public var body: some View {
        HStack(spacing: HaloSpacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(HaloColor.textSecondary).accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(HaloColor.textSecondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, HaloSpacing.m)
        .frame(minHeight: 38)
        .background(HaloColor.textSecondary.opacity(0.12), in: .capsule)
    }
}
#endif
