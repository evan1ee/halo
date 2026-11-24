#if canImport(UIKit)
import HaloDesignSystem
import SwiftUI

/// The Stickers tab of the composer's expression panel (docs/features/COMPOSER_PANELS.md §5): the user's own Matrix sticker
/// packs, and — when the build has a KLIPY key — KLIPY stickers as a separate source (KLIPY's rules keep its content in its
/// own grid). The chosen source is remembered.
public struct StickerTabView: View {
    enum Source: String { case packs, klipy }

    let packs: StickerPanelViewModel
    let klipy: KlipyPanelModel?
    @AppStorage("halo.composer.stickerSource") private var source = Source.packs.rawValue

    public init(packs: StickerPanelViewModel, klipy: KlipyPanelModel?) {
        self.packs = packs
        self.klipy = klipy
    }

    public var body: some View {
        VStack(spacing: 0) {
            if klipy != nil {
                Picker("Sticker source", selection: $source) {
                    Text("My stickers").tag(Source.packs.rawValue)
                    Text("KLIPY").tag(Source.klipy.rawValue)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, HaloSpacing.m)
                .padding(.top, HaloSpacing.s)
                .accessibilityIdentifier("sticker-source")
            }
            if source == Source.klipy.rawValue, let klipy {
                KlipyPanelView(model: klipy)
            } else {
                StickerPanelView(model: packs, embedded: true)
            }
        }
    }
}
#endif
