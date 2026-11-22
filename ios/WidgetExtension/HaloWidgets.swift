import HaloDomain
import HaloPlatform
import SwiftUI
import WidgetKit

/// Halo's widgets (M16, D89): the unread count the app last evaluated. No chat names and no message text, so a locked
/// phone shows no more than the app icon badge does. Tapping opens the app.
@main
struct HaloWidgetBundle: WidgetBundle {
    var body: some Widget { UnreadWidget() }
}

struct UnreadEntry: TimelineEntry {
    let date: Date
    let snapshot: UnreadWidgetSnapshot
}

struct UnreadProvider: TimelineProvider {
    private func current(at date: Date = Date()) -> UnreadEntry {
        let cache = AttentionCache(suiteName: "group.\(HaloShared.namespace())")
        return UnreadEntry(date: date, snapshot: UnreadWidgetSnapshot(counts: cache.counts(), updatedAt: cache.updatedAt()))
    }

    func placeholder(in context: Context) -> UnreadEntry {
        UnreadEntry(date: Date(), snapshot: UnreadWidgetSnapshot(counts: ["!placeholder:halo": 3], updatedAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    /// The app reloads the timeline whenever it writes new counts; the fallback keeps "possibly out of date" honest.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        let entry = current()
        let next = entry.date.addingTimeInterval(UnreadWidgetSnapshot.staleAfter + 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct UnreadWidget: Widget {
    let kind = "one.mbm.halo.widget.unread"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UnreadProvider()) { entry in
            UnreadWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Unread")
        .description("How many messages are waiting in Halo.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct UnreadWidgetView: View {
    let entry: UnreadEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: UnreadWidgetSnapshot { entry.snapshot }
    private var stale: Bool { snapshot.isStale(at: entry.date) }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "bubble.left.fill").font(.caption2)
                    Text(snapshot.countText).font(.headline).minimumScaleFactor(0.6).privacySensitive()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(snapshot.summary)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label("Halo", systemImage: "bubble.left.fill").font(.caption)
                Text(snapshot.summary).font(.headline).privacySensitive()
                if stale { Text("May be out of date").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text(snapshot.totalUnread == 0 ? "Halo: no unread" : "Halo: \(snapshot.countText) unread").privacySensitive()
        default:
            VStack(alignment: .leading, spacing: 4) {
                Label("Halo", systemImage: "bubble.left.fill").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(snapshot.countText).font(.system(.largeTitle, design: .rounded, weight: .bold)).privacySensitive()
                Text(snapshot.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                if stale, let updated = snapshot.updatedAt {
                    Text("As of \(updated, style: .time)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
