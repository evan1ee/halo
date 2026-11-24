import HaloDomain
import HaloPlatform
import SwiftUI
import WidgetKit

/// Halo's widgets (M16, D89): the unread count the app last evaluated. No chat names and no message text, so a locked
/// phone shows no more than the app icon badge does. Tapping opens the app.
@main
struct HaloWidgetBundle: WidgetBundle {
    var body: some Widget {
        UnreadWidget()
        UnreadChatsWidget()
    }
}

struct UnreadEntry: TimelineEntry {
    let date: Date
    let snapshot: UnreadWidgetSnapshot
}

struct UnreadProvider: TimelineProvider {
    private func current(at date: Date = Date(), renderedAs kind: String? = nil) -> UnreadEntry {
        let cache = AttentionCache(suiteName: "group.\(HaloShared.namespace())")
        let counts = cache.counts()
        if let kind { cache.markRendered(counts, widget: kind) }
        return UnreadEntry(date: date, snapshot: UnreadWidgetSnapshot(counts: counts, updatedAt: cache.updatedAt()))
    }

    func placeholder(in context: Context) -> UnreadEntry {
        UnreadEntry(date: Date(), snapshot: UnreadWidgetSnapshot(counts: ["!placeholder:halo": 3], updatedAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    /// The app reloads the timeline whenever it writes new counts; the fallback keeps "possibly out of date" honest.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        let entry = current(renderedAs: UnreadWidget.kind)
        let next = entry.date.addingTimeInterval(UnreadWidgetSnapshot.staleAfter + 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct UnreadWidget: Widget {
    static let kind = "one.mbm.halo.widget.unread"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UnreadProvider()) { entry in
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

// MARK: Unread chats (medium)

struct UnreadChatsEntry: TimelineEntry {
    let date: Date
    let snapshot: UnreadChatsSnapshot
}

/// Names come from the opt-in chat list (D88, D93); with the setting off the widget only says how to turn them on.
struct UnreadChatsProvider: TimelineProvider {
    private func current(at date: Date = Date(), renderedAs kind: String? = nil) -> UnreadChatsEntry {
        let cache = AttentionCache(suiteName: "group.\(HaloShared.namespace())")
        let counts = cache.counts()
        if let kind { cache.markRendered(counts, widget: kind) }
        let names = Dictionary(
            SystemChatShortcutStore(file: SystemChatShortcutStore.defaultFile()).load().map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first })
        return UnreadChatsEntry(date: date, snapshot: UnreadChatsSnapshot(counts: counts, names: names, updatedAt: cache.updatedAt()))
    }

    func placeholder(in context: Context) -> UnreadChatsEntry {
        UnreadChatsEntry(date: Date(), snapshot: UnreadChatsSnapshot(
            counts: ["!1:halo": 3, "!2:halo": 1], names: ["!1:halo": "Family", "!2:halo": "Project"], updatedAt: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadChatsEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadChatsEntry>) -> Void) {
        let entry = current(renderedAs: UnreadChatsWidget.kind)
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(UnreadWidgetSnapshot.staleAfter + 60))))
    }
}

struct UnreadChatsWidget: Widget {
    static let kind = "one.mbm.halo.widget.unread-chats"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UnreadChatsProvider()) { entry in
            UnreadChatsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Unread chats")
        .description("The chats with the most unread messages. Needs \"Chats in Siri and Spotlight\" in Halo's settings.")
        .supportedFamilies([.systemMedium])
    }
}

struct UnreadChatsWidgetView: View {
    let entry: UnreadChatsEntry
    private var snapshot: UnreadChatsSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Halo", systemImage: "bubble.left.fill").font(.caption).foregroundStyle(.secondary)
            if snapshot.rows.isEmpty {
                Spacer(minLength: 0)
                Text(snapshot.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 0)
            } else {
                ForEach(snapshot.rows) { row in
                    HStack {
                        Text(row.name).font(.subheadline).lineLimit(1).privacySensitive()
                        Spacer()
                        Text("\(row.unread)").font(.subheadline.bold()).monospacedDigit().privacySensitive()
                    }
                }
                if snapshot.moreCount > 0 {
                    Text("+\(snapshot.moreCount) more").font(.caption).foregroundStyle(.secondary)
                }
                if let updated = snapshot.updatedAt, UnreadWidgetSnapshot.isStale(updated, at: entry.date) {
                    Text("As of \(updated, style: .time)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
