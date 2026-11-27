import Foundation
import HaloDomain
import SwiftUI

/// Structured, safe representation of Matrix HTML `formatted_body` (TIMELINE FR-13, M20-10):
/// fenced code blocks with language + copy, `data-mx-spoiler` with optional reason, bounded tables,
/// nested ordered/unordered lists, headings, and blockquotes.
///
/// Pure Swift linear-time parser: never uses a WebView or `NSAttributedString(.html)`, never executes scripts,
/// never fetches remote resources, and enforces strict caps on input size, nesting depth, and table dimensions
/// so hostile HTML cannot freeze or break layout.
public struct RichTextDocument: Equatable, Sendable {
    public let blocks: [Block]
    /// `true` when the message contains structured blocks (code blocks, spoilers, tables, quotes, headings,
    /// dividers, or multi-level/rich lists) that should render with `RichTextMessageView`.
    public let needsRichRendering: Bool

    public init(blocks: [Block], needsRichRendering: Bool) {
        self.blocks = blocks
        self.needsRichRendering = needsRichRendering
    }

    public enum Block: Equatable, Sendable {
        case text([InlineSegment])
        case heading(level: Int, segments: [InlineSegment])
        case codeBlock(language: String?, code: String)
        case quote([InlineSegment])
        case list([ListItem])
        case table(Table)
        case divider
    }

    public enum InlineSegment: Equatable, Sendable {
        case styled(AttributedString)
        case spoiler(reason: String?, content: AttributedString)
    }

    public struct ListItem: Equatable, Sendable {
        public let depth: Int
        public let marker: String
        public let segments: [InlineSegment]

        public init(depth: Int, marker: String, segments: [InlineSegment]) {
            self.depth = depth
            self.marker = marker
            self.segments = segments
        }
    }

    public struct Table: Equatable, Sendable {
        public let headers: [String]
        public let rows: [[String]]
        public let truncated: Bool

        public init(headers: [String], rows: [[String]], truncated: Bool = false) {
            self.headers = headers
            self.rows = rows
            self.truncated = truncated
        }
    }
}

public enum RichTextParser {
    public static let maxInputLength = 65_536
    public static let maxBlocks = 100
    public static let maxNestingDepth = 6
    public static let maxListItems = 200
    public static let maxTableColumns = 12
    public static let maxTableRows = 50
    public static let maxCellCharacters = 240
    public static let maxCodeCharacters = 16_384

    private static let allowedSchemes: Set<String> = ["http", "https", "mailto", "matrix"]
    private static let droppedSubtreeTags: Set<String> = ["mx-reply", "script", "style", "iframe", "object", "embed", "svg", "math"]

    public static func parse(_ rawHTML: String, edited: Bool = false) -> RichTextDocument {
        let html: String
        if rawHTML.count > maxInputLength {
            html = String(rawHTML.prefix(maxInputLength))
        } else {
            html = rawHTML
        }

        var parser = ParserState(html: html)
        parser.run()
        var blocks = parser.blocks

        if edited {
            appendEditedSuffix(to: &blocks)
        }

        let needsRich = blocks.contains { block in
            switch block {
            case .codeBlock, .table, .quote, .heading, .divider, .list:
                return true
            case .text(let segments):
                return segments.contains { if case .spoiler = $0 { return true }; return false }
            }
        }
        return RichTextDocument(blocks: blocks, needsRichRendering: needsRich)
    }

    private static func appendEditedSuffix(to blocks: inout [RichTextDocument.Block]) {
        let suffix = AttributedString(" (edited)")
        guard let last = blocks.last else {
            blocks.append(.text([.styled(AttributedString("(edited)"))]))
            return
        }
        switch last {
        case .text(var segments):
            if case .styled(var attr) = segments.last {
                attr += suffix
                segments[segments.count - 1] = .styled(attr)
            } else {
                segments.append(.styled(suffix))
            }
            blocks[blocks.count - 1] = .text(segments)
        default:
            blocks.append(.text([.styled(AttributedString("(edited)"))]))
        }
    }

    // MARK: - Single-pass linear parser

    private struct ParserState {
        let html: String
        var blocks: [RichTextDocument.Block] = []

        // Inline state
        var bold = 0
        var italic = 0
        var strike = 0
        var underline = 0
        var inlineCode = 0
        var links: [URL?] = []

        // Current inline accumulator
        var currentStyled = AttributedString()
        var currentSegments: [RichTextDocument.InlineSegment] = []

        // Spoiler state
        var spoilerDepth = 0
        var spoilerReason: String?
        var spoilerBuffer = AttributedString()

        // Container state
        var skipDepth = 0
        var preDepth = 0
        var preLanguage: String?
        var preBuffer = ""

        var headingLevel: Int?
        var blockquoteDepth = 0

        struct ListLevel {
            let ordered: Bool
            var count: Int
        }
        var listStack: [ListLevel] = []
        var activeListItems: [RichTextDocument.ListItem] = []
        var inListItem = false
        var activeItemDepth = 0
        var activeItemMarker = "•"

        // Table state
        var tableDepth = 0
        var inTableHead = false
        var inTableCell = false
        var cellIsHeader = false
        var cellBuffer = ""
        var currentRow: [String] = []
        var currentRowIsHeader = false
        var tableHeaders: [String] = []
        var tableRows: [[String]] = []
        var tableTruncated = false

        mutating func run() {
            var index = html.startIndex
            while index < html.endIndex {
                if blocks.count >= RichTextParser.maxBlocks { break }
                if html[index] == "<", let close = html[index...].firstIndex(of: ">") {
                    let rawTag = String(html[html.index(after: index)..<close])
                    index = html.index(after: close)
                    handleTag(parseTag(rawTag))
                } else {
                    let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                    let end = next == index ? html.index(after: index) : next
                    let text = HTMLEntities.decode(String(html[index..<end]))
                    handleText(text)
                    index = end
                }
            }
            finalizeAll()
        }

        private mutating func handleTag(_ tag: ParsedTag) {
            if RichTextParser.droppedSubtreeTags.contains(tag.name) {
                if !tag.isSelfClosing {
                    if tag.isClosing {
                        skipDepth = max(0, skipDepth - 1)
                    } else {
                        skipDepth += 1
                    }
                }
                return
            }
            guard skipDepth == 0 else { return }

            // Inside <pre>
            if preDepth > 0 {
                if tag.name == "pre", tag.isClosing {
                    preDepth -= 1
                    if preDepth == 0 {
                        flushPreBlock()
                    }
                } else if tag.name == "code", !tag.isClosing, preLanguage == nil {
                    preLanguage = tag.codeLanguage
                } else if tag.name == "br" {
                    appendPreText("\n")
                }
                return
            }

            // Inside <table>
            if tableDepth > 0 {
                handleTableTag(tag)
                return
            }

            switch (tag.name, tag.isClosing) {
            case ("pre", false):
                flushCurrentContainerBlock()
                flushActiveList()
                preDepth = 1
                preLanguage = tag.codeLanguage
                preBuffer = ""

            case ("table", false):
                flushCurrentContainerBlock()
                flushActiveList()
                tableDepth = 1
                inTableHead = false
                inTableCell = false
                cellBuffer = ""
                currentRow = []
                currentRowIsHeader = false
                tableHeaders = []
                tableRows = []
                tableTruncated = false

            case ("hr", _):
                flushCurrentContainerBlock()
                flushActiveList()
                appendBlock(.divider)

            case ("h1", false), ("h2", false), ("h3", false), ("h4", false), ("h5", false), ("h6", false):
                flushCurrentContainerBlock()
                flushActiveList()
                headingLevel = Int(String(tag.name.dropFirst())) ?? 1

            case ("h1", true), ("h2", true), ("h3", true), ("h4", true), ("h5", true), ("h6", true):
                flushHeading()

            case ("blockquote", false):
                if blockquoteDepth == 0 {
                    flushCurrentContainerBlock()
                    flushActiveList()
                }
                blockquoteDepth = min(blockquoteDepth + 1, RichTextParser.maxNestingDepth)

            case ("blockquote", true):
                if blockquoteDepth > 0 {
                    blockquoteDepth -= 1
                    if blockquoteDepth == 0 {
                        flushQuote()
                    }
                }

            case ("ul", false):
                if listStack.isEmpty {
                    flushCurrentContainerBlock()
                } else if inListItem {
                    finishCurrentListItem()
                }
                listStack.append(ListLevel(ordered: false, count: 0))

            case ("ol", false):
                if listStack.isEmpty {
                    flushCurrentContainerBlock()
                } else if inListItem {
                    finishCurrentListItem()
                }
                let start = max(1, min(tag.listStart ?? 1, 9_999))
                listStack.append(ListLevel(ordered: true, count: start - 1))

            case ("ul", true), ("ol", true):
                if inListItem { finishCurrentListItem() }
                if !listStack.isEmpty { listStack.removeLast() }
                if listStack.isEmpty { flushActiveList() }

            case ("li", false):
                if inListItem { finishCurrentListItem() }
                if listStack.isEmpty {
                    listStack.append(ListLevel(ordered: false, count: 0))
                }
                var top = listStack.removeLast()
                top.count += 1
                listStack.append(top)
                activeItemDepth = min(max(0, listStack.count - 1), RichTextParser.maxNestingDepth - 1)
                activeItemMarker = top.ordered ? "\(top.count)." : "•"
                inListItem = true

            case ("li", true):
                if inListItem { finishCurrentListItem() }

            case ("p", false), ("div", false):
                if !inListItem && blockquoteDepth == 0 && headingLevel == nil {
                    flushParagraph()
                } else {
                    appendNewlineIfNeeded()
                }

            case ("p", true), ("div", true):
                if !inListItem && blockquoteDepth == 0 && headingLevel == nil {
                    flushParagraph()
                } else {
                    appendNewlineIfNeeded()
                }

            case ("br", _):
                appendInlineText("\n")

            case ("span", false) where tag.hasSpoiler:
                if spoilerDepth == 0 {
                    flushStyledIntoSegments()
                    spoilerReason = tag.spoilerReason?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if spoilerReason?.isEmpty == true { spoilerReason = nil }
                    spoilerBuffer = AttributedString()
                }
                spoilerDepth += 1

            case ("span", true) where spoilerDepth > 0:
                spoilerDepth -= 1
                if spoilerDepth == 0 {
                    if !spoilerBuffer.characters.isEmpty {
                        currentSegments.append(.spoiler(reason: spoilerReason, content: spoilerBuffer))
                    }
                    spoilerReason = nil
                    spoilerBuffer = AttributedString()
                }

            case ("b", false), ("strong", false): bold += 1
            case ("b", true), ("strong", true): bold = max(0, bold - 1)
            case ("i", false), ("em", false): italic += 1
            case ("i", true), ("em", true): italic = max(0, italic - 1)
            case ("s", false), ("del", false), ("strike", false): strike += 1
            case ("s", true), ("del", true), ("strike", true): strike = max(0, strike - 1)
            case ("u", false): underline += 1
            case ("u", true): underline = max(0, underline - 1)
            case ("code", false): inlineCode += 1
            case ("code", true): inlineCode = max(0, inlineCode - 1)
            case ("a", false): links.append(tag.href.flatMap(RichTextParser.safeURL))
            case ("a", true): if !links.isEmpty { links.removeLast() }
            default: break
            }
        }

        private mutating func handleTableTag(_ tag: ParsedTag) {
            switch (tag.name, tag.isClosing) {
            case ("table", false):
                // Nested tables are flattened inside the outer table to keep layout safe.
                tableDepth += 1
            case ("table", true):
                tableDepth -= 1
                if tableDepth == 0 {
                    finishTableCellIfNeeded()
                    finishTableRowIfNeeded()
                    flushTable()
                }
            case ("thead", false): inTableHead = true
            case ("thead", true): inTableHead = false
            case ("tr", false):
                finishTableCellIfNeeded()
                finishTableRowIfNeeded()
                currentRow = []
                currentRowIsHeader = inTableHead
            case ("tr", true):
                finishTableCellIfNeeded()
                finishTableRowIfNeeded()
            case ("th", false):
                finishTableCellIfNeeded()
                inTableCell = true
                cellIsHeader = true
                cellBuffer = ""
            case ("td", false):
                finishTableCellIfNeeded()
                inTableCell = true
                cellIsHeader = false
                cellBuffer = ""
            case ("th", true), ("td", true):
                finishTableCellIfNeeded()
            case ("br", _):
                if inTableCell, cellBuffer.count < RichTextParser.maxCellCharacters {
                    cellBuffer.append(" ")
                }
            default:
                break
            }
        }

        private mutating func finishTableCellIfNeeded() {
            guard inTableCell else { return }
            inTableCell = false
            if currentRow.count < RichTextParser.maxTableColumns {
                let cleaned = cellBuffer
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentRow.append(cleaned)
                if cellIsHeader { currentRowIsHeader = true }
            } else {
                tableTruncated = true
            }
            cellBuffer = ""
            cellIsHeader = false
        }

        private mutating func finishTableRowIfNeeded() {
            guard !currentRow.isEmpty else { return }
            if currentRowIsHeader && tableHeaders.isEmpty {
                tableHeaders = currentRow
            } else if tableRows.count < RichTextParser.maxTableRows {
                tableRows.append(currentRow)
            } else {
                tableTruncated = true
            }
            currentRow = []
            currentRowIsHeader = false
        }

        private mutating func flushTable() {
            let maxCols = max(tableHeaders.count, tableRows.map(\.count).max() ?? 0)
            guard maxCols > 0 else { return }
            let clampedCols = min(maxCols, RichTextParser.maxTableColumns)
            let normalizedHeaders: [String] = tableHeaders.isEmpty
                ? []
                : tableHeaders.prefix(clampedCols) + Array(repeating: "", count: max(0, clampedCols - tableHeaders.count))
            let normalizedRows: [[String]] = tableRows.map { row in
                Array(row.prefix(clampedCols)) + Array(repeating: "", count: max(0, clampedCols - row.count))
            }
            appendBlock(.table(RichTextDocument.Table(
                headers: normalizedHeaders,
                rows: normalizedRows,
                truncated: tableTruncated
            )))
            tableHeaders = []
            tableRows = []
            tableTruncated = false
        }

        private mutating func handleText(_ text: String) {
            guard skipDepth == 0, !text.isEmpty else { return }
            if preDepth > 0 {
                appendPreText(text)
                return
            }
            if tableDepth > 0 {
                if inTableCell {
                    let remaining = RichTextParser.maxCellCharacters - cellBuffer.count
                    if remaining > 0 {
                        if text.count <= remaining {
                            cellBuffer += text
                        } else {
                            cellBuffer += String(text.prefix(remaining)) + "…"
                            tableTruncated = true
                        }
                    }
                }
                return
            }
            // Ignore inter-element whitespace between list/table structure tags when outside a list item.
            if !listStack.isEmpty && !inListItem && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            appendInlineText(text)
        }

        private mutating func appendPreText(_ text: String) {
            let remaining = RichTextParser.maxCodeCharacters - preBuffer.count
            guard remaining > 0 else { return }
            if text.count <= remaining {
                preBuffer += text
            } else {
                preBuffer += String(text.prefix(remaining)) + "\n…"
            }
        }

        private mutating func appendInlineText(_ text: String) {
            var piece = AttributedString(text)
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if strike > 0 { intent.insert(.strikethrough) }
            if inlineCode > 0 {
                intent.insert(.code)
                piece.font = .system(.body, design: .monospaced)
            }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if underline > 0 { piece.underlineStyle = .single }
            if let link = links.last, let url = link { piece.link = url }

            if spoilerDepth > 0 {
                spoilerBuffer += piece
            } else {
                currentStyled += piece
            }
        }

        private mutating func appendNewlineIfNeeded() {
            if spoilerDepth > 0 {
                if !spoilerBuffer.characters.isEmpty, spoilerBuffer.characters.last != "\n" {
                    spoilerBuffer += AttributedString("\n")
                }
            } else if !currentStyled.characters.isEmpty, currentStyled.characters.last != "\n" {
                currentStyled += AttributedString("\n")
            }
        }

        private mutating func flushStyledIntoSegments() {
            guard !currentStyled.characters.isEmpty else { return }
            currentSegments.append(.styled(currentStyled))
            currentStyled = AttributedString()
        }

        private mutating func takeTrimmedSegments() -> [RichTextDocument.InlineSegment] {
            if spoilerDepth > 0 && !spoilerBuffer.characters.isEmpty {
                currentSegments.append(.spoiler(reason: spoilerReason, content: spoilerBuffer))
                spoilerBuffer = AttributedString()
                spoilerReason = nil
                spoilerDepth = 0
            }
            flushStyledIntoSegments()
            var segments = currentSegments
            currentSegments = []
            // Trim leading/trailing newlines on edge styled segments.
            while let first = segments.first, case .styled(var attr) = first {
                while attr.characters.first == "\n" { attr.removeSubrange(attr.startIndex..<attr.index(afterCharacter: attr.startIndex)) }
                if attr.characters.isEmpty {
                    segments.removeFirst()
                } else {
                    segments[0] = .styled(attr)
                    break
                }
            }
            while let last = segments.last, case .styled(var attr) = last {
                while let ch = attr.characters.last, ch == "\n" || ch == " " || ch == "\t" {
                    let prev = attr.index(beforeCharacter: attr.endIndex)
                    attr.removeSubrange(prev..<attr.endIndex)
                }
                if attr.characters.isEmpty {
                    segments.removeLast()
                } else {
                    segments[segments.count - 1] = .styled(attr)
                    break
                }
            }
            // Drop whitespace-only text blocks.
            let hasContent = segments.contains { seg in
                switch seg {
                case .spoiler(_, let content): !String(content.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                case .styled(let attr): !String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            return hasContent ? segments : []
        }

        private mutating func flushParagraph() {
            let segments = takeTrimmedSegments()
            guard !segments.isEmpty else { return }
            appendBlock(.text(segments))
        }

        private mutating func flushHeading() {
            guard let level = headingLevel else { return }
            headingLevel = nil
            let segments = takeTrimmedSegments()
            guard !segments.isEmpty else { return }
            appendBlock(.heading(level: level, segments: segments))
        }

        private mutating func flushQuote() {
            let segments = takeTrimmedSegments()
            guard !segments.isEmpty else { return }
            appendBlock(.quote(segments))
        }

        private mutating func finishCurrentListItem() {
            guard inListItem else { return }
            inListItem = false
            let segments = takeTrimmedSegments()
            guard !segments.isEmpty, activeListItems.count < RichTextParser.maxListItems else { return }
            activeListItems.append(RichTextDocument.ListItem(
                depth: activeItemDepth,
                marker: activeItemMarker,
                segments: segments
            ))
        }

        private mutating func flushActiveList() {
            finishCurrentListItem()
            guard !activeListItems.isEmpty else { return }
            appendBlock(.list(activeListItems))
            activeListItems = []
        }

        private mutating func flushPreBlock() {
            var code = preBuffer
            if code.hasSuffix("\n") { code.removeLast() }
            preBuffer = ""
            let lang = preLanguage
            preLanguage = nil
            guard !code.isEmpty else { return }
            appendBlock(.codeBlock(language: lang, code: code))
        }

        private mutating func flushCurrentContainerBlock() {
            if headingLevel != nil {
                flushHeading()
            } else if blockquoteDepth > 0 {
                flushQuote()
            } else if inListItem {
                finishCurrentListItem()
            } else {
                flushParagraph()
            }
        }

        private mutating func appendBlock(_ block: RichTextDocument.Block) {
            guard blocks.count < RichTextParser.maxBlocks else { return }
            blocks.append(block)
        }

        private mutating func finalizeAll() {
            if preDepth > 0 {
                preDepth = 0
                flushPreBlock()
            }
            if tableDepth > 0 {
                tableDepth = 0
                finishTableCellIfNeeded()
                finishTableRowIfNeeded()
                flushTable()
            }
            if !listStack.isEmpty || !activeListItems.isEmpty {
                listStack.removeAll()
                flushActiveList()
            }
            if headingLevel != nil {
                flushHeading()
            } else if blockquoteDepth > 0 {
                blockquoteDepth = 0
                flushQuote()
            } else {
                flushParagraph()
            }
        }
    }

    // MARK: - Linear attribute tokenizer (no regex backtracking)

    private struct ParsedTag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let href: String?
        let codeLanguage: String?
        let hasSpoiler: Bool
        let spoilerReason: String?
        let listStart: Int?
    }

    private static func parseTag(_ raw: String) -> ParsedTag {
        var body = Substring(raw).trimmingWhitespace()
        let isClosing = body.hasPrefix("/")
        if isClosing { body = body.dropFirst().trimmingWhitespace() }
        let isSelfClosing = body.hasSuffix("/")
        if isSelfClosing { body = body.dropLast().trimmingWhitespace() }

        let nameEnd = body.firstIndex { $0.isWhitespace || $0 == "/" } ?? body.endIndex
        let name = body[..<nameEnd].lowercased()
        let attrSlice = body[nameEnd...]

        var href: String?
        var codeLanguage: String?
        var hasSpoiler = false
        var spoilerReason: String?
        var listStart: Int?

        if !isClosing && !attrSlice.isEmpty {
            var i = attrSlice.startIndex
            while i < attrSlice.endIndex {
                while i < attrSlice.endIndex && attrSlice[i].isWhitespace { i = attrSlice.index(after: i) }
                guard i < attrSlice.endIndex else { break }

                let keyStart = i
                while i < attrSlice.endIndex && !attrSlice[i].isWhitespace && attrSlice[i] != "=" && attrSlice[i] != "/" {
                    i = attrSlice.index(after: i)
                }
                let key = attrSlice[keyStart..<i].lowercased()
                while i < attrSlice.endIndex && attrSlice[i].isWhitespace { i = attrSlice.index(after: i) }

                var value: String?
                if i < attrSlice.endIndex && attrSlice[i] == "=" {
                    i = attrSlice.index(after: i)
                    while i < attrSlice.endIndex && attrSlice[i].isWhitespace { i = attrSlice.index(after: i) }
                    if i < attrSlice.endIndex && (attrSlice[i] == "\"" || attrSlice[i] == "'") {
                        let quote = attrSlice[i]
                        i = attrSlice.index(after: i)
                        let valStart = i
                        while i < attrSlice.endIndex && attrSlice[i] != quote { i = attrSlice.index(after: i) }
                        value = HTMLEntities.decode(String(attrSlice[valStart..<i]))
                        if i < attrSlice.endIndex { i = attrSlice.index(after: i) }
                    } else {
                        let valStart = i
                        while i < attrSlice.endIndex && !attrSlice[i].isWhitespace { i = attrSlice.index(after: i) }
                        value = HTMLEntities.decode(String(attrSlice[valStart..<i]))
                    }
                }

                switch key {
                case "href":
                    href = value
                case "class":
                    if let classes = value?.split(whereSeparator: \.isWhitespace) {
                        for cls in classes where cls.hasPrefix("language-") {
                            let lang = String(cls.dropFirst("language-".count))
                            if !lang.isEmpty { codeLanguage = lang; break }
                        }
                    }
                case "data-mx-spoiler":
                    hasSpoiler = true
                    if let value, !value.isEmpty { spoilerReason = value }
                case "start":
                    if let value, let parsed = Int(value) { listStart = parsed }
                default:
                    break
                }
            }
        }

        return ParsedTag(
            name: name,
            isClosing: isClosing,
            isSelfClosing: isSelfClosing,
            href: href,
            codeLanguage: codeLanguage,
            hasSpoiler: hasSpoiler,
            spoilerReason: spoilerReason,
            listStart: listStart
        )
    }

    private static func safeURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        return url
    }
}

private extension Substring {
    func trimmingWhitespace() -> Substring {
        var s = self
        while let first = s.first, first.isWhitespace { s = s.dropFirst() }
        while let last = s.last, last.isWhitespace { s = s.dropLast() }
        return s
    }
}
