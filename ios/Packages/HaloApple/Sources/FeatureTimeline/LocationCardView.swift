#if canImport(SwiftUI) && canImport(UIKit) && canImport(MapKit)
import HaloDesignSystem
import MapKit
import SwiftUI

/// Renders a shared `m.location` message as a compact static MapKit snapshot card with a centered pin and Apple Maps deep link.
struct LocationCardView: View {
    let location: TimelineRow.Location
    let isOwn: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: UIImage?

    private let mapAspectRatio: CGFloat = 240.0 / 136.0
    private let snapshotSize = CGSize(width: 340, height: 193)

    var body: some View {
        Button {
            if let url = location.mapsURL {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HaloColor.bgSecondary
                    .aspectRatio(mapAspectRatio, contentMode: .fit)
                    .overlay {
                        if let snapshot {
                            Image(uiImage: snapshot)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "map")
                                .font(.title2)
                                .foregroundStyle(HaloColor.textSecondary)
                        }
                    }
                    .overlay {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(HaloColor.onAccent, HaloColor.danger)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    }
                    .clipped()

                HStack(spacing: HaloSpacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.title)
                            .font(HaloTypography.headline)
                            .foregroundStyle(HaloColor.textPrimary)
                            .lineLimit(1)
                        Text(location.subtitle)
                            .font(HaloTypography.caption)
                            .foregroundStyle(HaloColor.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: HaloSpacing.xs)
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(HaloColor.accent)
                }
                .padding(.horizontal, HaloSpacing.s)
                .padding(.vertical, HaloSpacing.s)
            }
            .frame(maxWidth: .infinity)
            .background(isOwn ? HaloColor.bubbleOwn : HaloColor.bubbleOther)
            .clipShape(RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
        }
        .buttonStyle(ScrollFriendlyTapButtonStyle())
        .accessibilityLabel("\(location.title), \(location.subtitle)")
        .accessibilityHint("Opens in Apple Maps")
        .task(id: snapshotCacheKey) {
            if let cached = LocationSnapshotCache.shared.image(forKey: snapshotCacheKey) {
                snapshot = cached
                return
            }
            snapshot = await renderSnapshot()
            if let snapshot {
                LocationSnapshotCache.shared.store(snapshot, forKey: snapshotCacheKey)
            }
        }
    }

    private var snapshotCacheKey: String {
        let mode = colorScheme == .dark ? "dark" : "light"
        return String(format: "%.5f,%.5f:%@", location.latitude, location.longitude, mode)
    }

    private func renderSnapshot() async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
            latitudinalMeters: 600,
            longitudinalMeters: 600
        )
        options.size = snapshotSize
        options.traitCollection = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let snapshotter = MKMapSnapshotter(options: options)
        return try? await snapshotter.start().image  // best-effort: a picture that can't load shows its placeholder; nothing changes
    }
}

@MainActor
private final class LocationSnapshotCache {
    static let shared = LocationSnapshotCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 40
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
#endif
