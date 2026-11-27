#if canImport(UIKit)
import Foundation
import HaloApplication
import HaloBotRendering
import HaloDesignSystem
import HaloDomain
import HaloFoundation
import HaloTestSupport
import SwiftUI
import Testing
import UIKit
@testable import FeatureTimeline

@MainActor
@Suite("Rich text rendering (code blocks, spoilers, tables, lists; TIMELINE FR-13, M20-10)")
struct RichTextRenderingTests {
    @Test("TimelineViewModel routes rich HTML blocks to richText and keeps simple inline HTML on the fast path")
    func richTextMappingFastPath() throws {
        let vm = TimelineViewModel(
            coordinator: TimelineCoordinator(port: FakeTimelinePort(), room: try RoomID("!r:example.org")),
            locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC") ?? .gmt
        )
        let alice = try UserID("@alice:example.org")
        func makeItem(body: String, html: String?) -> TimelineItem {
            TimelineItem(id: TimelineItemID("id"), content: .event(TimelineEvent(
                eventID: try? EventID("$e1"), sender: alice, senderName: "Alice",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000), isOwn: false,
                kind: .text(body, isEdited: false), formattedBody: html
            )))
        }

        let simple = vm.row(makeItem(body: "hello", html: "hello <b>world</b>"))
        #expect(simple.richText == nil)
        #expect(simple.styled != nil)

        let code = vm.row(makeItem(body: "code", html: #"<pre><code class="language-swift">let x = 1</code></pre>"#))
        #expect(code.richText?.needsRichRendering == true)

        let spoiler = vm.row(makeItem(body: "secret", html: #"<span data-mx-spoiler="Hint">42</span>"#))
        #expect(spoiler.richText?.needsRichRendering == true)

        let table = vm.row(makeItem(body: "tbl", html: "<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>"))
        #expect(table.richText?.needsRichRendering == true)
    }

    @Test("RichTextMessageView renders code block, hidden/revealed spoilers, table, nested list, and quote in Light, Dark, and AX5")
    func richTextLightDarkAX5Snapshots() throws {
        let sampleHTML = """
        <h3>Release checklist</h3>
        <p>Check the snippet and <span data-mx-spoiler="Ending">the answer is 42</span> plus <span data-mx-spoiler>hidden note</span>:</p>
        <pre><code class="language-swift">struct Config {
            let timeoutSeconds = 15
            let safeMode = true
        }
        </code></pre>
        <blockquote><p>Always verify in Light, Dark, and AX5.</p></blockquote>
        <table>
          <thead><tr><th>Milestone</th><th>Status</th><th>Owner</th></tr></thead>
          <tbody>
            <tr><td>M20-9</td><td>Merged</td><td>Timeline</td></tr>
            <tr><td>M20-10</td><td>In progress</td><td>Rendering</td></tr>
          </tbody>
        </table>
        <ol start="1">
          <li>Parse HTML safely
            <ul><li>Drop scripts &amp; trackers</li><li>Clamp table size</li></ul>
          </li>
          <li>Verify live Synapse</li>
        </ol>
        """
        let doc = RichTextParser.parse(sampleHTML)
        #expect(doc.needsRichRendering)

        let outDir = ProcessInfo.processInfo.environment["HALO_RICHTEXT_SNAPSHOT_DIR"]
        let configs: [(name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize)] = [
            ("light", .light, .large),
            ("dark", .dark, .large),
            ("ax5", .light, .accessibility5),
        ]

        for config in configs {
            let preview = VStack(alignment: .leading, spacing: HaloSpacing.m) {
                RichTextMessageView(
                    document: doc,
                    isOwn: false,
                    initiallyRevealedSpoilers: ["b1-3"]
                )
                .padding(HaloSpacing.s)
                .background(HaloColor.bubbleOther, in: RoundedRectangle(cornerRadius: HaloRadius.bubble, style: .continuous))
            }
            .padding(HaloSpacing.m)
            .frame(width: 390)
            .background(HaloColor.bgPrimary)
            .environment(\.dynamicTypeSize, config.size)
            .environment(\.colorScheme, config.style == .dark ? .dark : .light)

            let host = UIHostingController(rootView: preview)
            host.overrideUserInterfaceStyle = config.style
            let size = host.sizeThatFits(in: CGSize(width: 390, height: 10_000))
            #expect(size.width > 0 && size.height > 0)

            if let outDir {
                let renderer = ImageRenderer(content: preview)
                renderer.scale = config.size.isAccessibilitySize ? 1 : 2
                let image = try #require(renderer.uiImage)
                let png = try #require(image.pngData())
                let url = URL(fileURLWithPath: outDir).appendingPathComponent("richtext-\(config.name).png")
                try png.write(to: url)
            }
        }
    }
}
#endif
