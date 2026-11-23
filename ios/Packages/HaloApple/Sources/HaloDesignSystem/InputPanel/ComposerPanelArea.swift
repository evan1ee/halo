#if canImport(SwiftUI)
import SwiftUI

/// The space under the composer where Halo's panels take the keyboard's place (docs/features/COMPOSER_PANELS.md §3).
///
/// Its height follows `ComposerInputController.areaHeight` (the keyboard's height while the keyboard is up, the panel's
/// while a panel is shown), animated with the keyboard's measured curve. The panel itself is laid
/// out at its full height and pinned to the top, so as the area grows or shrinks the panel slides in from below like the
/// keyboard does instead of squashing. The background reaches under the home indicator.
public struct ComposerPanelArea<Content: View>: View {
    private let controller: ComposerInputController
    private let content: (ComposerPanel) -> Content

    public init(controller: ComposerInputController, @ViewBuilder content: @escaping (ComposerPanel) -> Content) {
        self.controller = controller
        self.content = content
    }

    public var body: some View {
        let area = controller.areaHeight
        let state = controller.state
        let full = state.panelSearching ? ComposerPanelMetrics.searchHeight
            : state.panelExpanded ? controller.expandedHeight : controller.panelHeight
        ZStack(alignment: .top) {
            if let panel = controller.state.displayedPanel {
                content(panel)
                    .frame(height: max(full, area), alignment: .top)
                    .transition(.opacity)
                    .id(panel)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: area, alignment: .top)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: HaloRadius.sheet, topTrailingRadius: HaloRadius.sheet, style: .continuous))
        .background(alignment: .top) {
            // Only under a panel: with the keyboard alone the area sits behind the (translucent) keyboard and stays clear.
            if area > 0, state.displayedPanel != nil {
                // Rounded top corners like the system keyboard's, so swapping the two keeps the same silhouette.
                UnevenRoundedRectangle(topLeadingRadius: HaloRadius.sheet, topTrailingRadius: HaloRadius.sheet, style: .continuous)
                    .fill(HaloColor.bgSecondary)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer-panel-area")
    }
}

/// A floating capsule that switches a panel's tabs ("GIFs · Stickers · Emoji", "Gallery · File"), drawn as Liquid Glass.
public struct PanelTabPill<Tab: Hashable & Identifiable>: View {
    public struct Item: Identifiable {
        public let tab: Tab
        public let title: String
        public let systemImage: String?
        public let identifier: String
        public var id: Tab.ID { tab.id }

        public init(tab: Tab, title: String, systemImage: String? = nil, identifier: String) {
            self.tab = tab
            self.title = title
            self.systemImage = systemImage
            self.identifier = identifier
        }
    }

    private let items: [Item]
    private let stacked: Bool
    @Binding private var selection: Tab
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameter stacked: icon above a small title (the attachment panel), instead of a one-line title.
    public init(items: [Item], selection: Binding<Tab>, stacked: Bool = false) {
        self.items = items
        self.stacked = stacked
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: HaloSpacing.xxs) {
            ForEach(items) { item in
                Button {
                    withAnimation(HaloMotion.stickerPanel(reduceMotion: reduceMotion)) { selection = item.tab }
                } label: {
                    Group {
                        if stacked, let symbol = item.systemImage {
                            // The tabs share the pill's width and the titles shrink to fit, so five tabs fit a narrow
                            // iPhone (17e) at large text sizes too (founder: "the tab's length is long").
                            VStack(spacing: HaloSpacing.xxs) {
                                Image(systemName: symbol).font(HaloTypography.title).frame(height: 26)
                                Text(item.title).font(HaloTypography.captionEmphasis).minimumScaleFactor(0.6)
                            }
                            .frame(maxWidth: .infinity)
                        } else if let symbol = item.systemImage {
                            Label(item.title, systemImage: symbol).font(HaloTypography.bodyEmphasis)
                        } else {
                            Text(item.title).font(HaloTypography.bodyEmphasis)
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(selection == item.tab ? (stacked ? HaloColor.accent : HaloColor.textPrimary) : HaloColor.textSecondary)
                    .padding(.horizontal, stacked ? HaloSpacing.xxs : HaloSpacing.l)
                    .padding(.vertical, stacked ? HaloSpacing.xs : 0)
                    .frame(minHeight: 44)
                    .background {
                        if selection == item.tab {
                            Capsule().fill(HaloColor.textPrimary.opacity(0.1)).matchedGeometryEffect(id: "tab", in: highlight)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == item.tab ? [.isSelected] : [])
                .accessibilityIdentifier(item.identifier)
            }
        }
        .padding(HaloSpacing.xs)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, stacked ? HaloSpacing.m : 0)
        .dynamicTypeSize(stacked ? ...DynamicTypeSize.xxLarge : ...DynamicTypeSize.accessibility5)
    }
}

/// A round Liquid Glass button for the composer row (attach, send) and panel corners.
public struct ComposerCircleButton: View {
    private let systemImage: String
    private let label: String
    private let prominent: Bool
    private let action: () -> Void

    public init(systemImage: String, label: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.prominent = prominent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(HaloTypography.headline)
                .foregroundStyle(prominent ? HaloColor.onAccent : HaloColor.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(prominent ? .regular.tint(HaloColor.accent).interactive() : .regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}
#endif
