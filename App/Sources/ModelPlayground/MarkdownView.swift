import SwiftUI

/// Lightweight block-level Markdown renderer for model output.
struct MarkdownView: View {
    var text: String
    var font: Font = Theme.serif

    /// Prose runs are drawn by one native text view each (fast, selectable across paragraphs);
    /// code blocks and tables keep their own views with copy buttons.
    enum Segment { case prose([Block], String), code(String, String), table([[String]]) }

    private var serif: Bool { font == Theme.serif }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownCache.segments(text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let blocks, let source):
                    SelectableText(text: RichTextBuilder.build(blocks, source: source, serif: serif))
                case .code(let lang, let code):
                    CodeBlock(language: lang, code: code)
                case .table(let rows):
                    TableBlock(rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            inline(s)
                .font(.system(size: level == 1 ? 22 : level == 2 ? 19 : 16.5, weight: .semibold, design: .serif))
                .padding(.top, 4)
        case .paragraph(let s):
            inline(s).font(font).lineSpacing(4)
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(i + 1)." : "•")
                            .font(font)
                            .foregroundStyle(Theme.secondaryText)
                            .frame(minWidth: ordered ? 20 : 10, alignment: .trailing)
                        inline(item.text).font(font).lineSpacing(3)
                    }
                    .padding(.leading, CGFloat(item.indent) * 18)
                }
            }
        case .quote(let s):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.border).frame(width: 3)
                inline(s).font(font).foregroundStyle(Theme.secondaryText)
            }
        case .code(let lang, let code):
            CodeBlock(language: lang, code: code)
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let rows):
            TableBlock(rows: rows)
        }
    }

    private func inline(_ s: String) -> Text {
        Text(MarkdownCache.inline(s))
    }

    // MARK: Parsing

    struct ListItem { var text: String; var indent: Int }

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case list([ListItem], ordered: Bool)
        case quote(String)
        case code(String, String)
        case rule
        case table([[String]])
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var listItems: [ListItem] = []
        var listOrdered = false
        var quote: [String] = []
        var table: [[String]] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !listItems.isEmpty { blocks.append(.list(listItems, ordered: listOrdered)); listItems = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flush()
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang, code.joined(separator: "\n")))
                i += 1
                continue
            }
            if line.isEmpty { flush(); i += 1; continue }

            if let m = line.firstMatch(of: Patterns.heading) {
                flush()
                blocks.append(.heading(m.1.count, String(m.2)))
            } else if line.firstMatch(of: Patterns.rule) != nil {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("|") && line.hasSuffix("|") {
                if !para.isEmpty || !listItems.isEmpty || !quote.isEmpty { flush() }
                let cells = line.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.firstMatch(of: Patterns.tableDivider) != nil }) { table.append(cells) }
            } else if line.hasPrefix(">") {
                if !para.isEmpty || !listItems.isEmpty || !table.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let m = raw.firstMatch(of: Patterns.listItem) {
                if !para.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                let ordered = m.2.first?.isNumber ?? false
                if listItems.isEmpty { listOrdered = ordered }
                listItems.append(ListItem(text: String(m.3), indent: min(m.1.count / 2, 4)))
            } else if !listItems.isEmpty && raw.hasPrefix("  ") {
                listItems[listItems.count - 1].text += " " + line  // continuation of a list item
            } else {
                if !listItems.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                para.append(line)
            }
            i += 1
        }
        flush()
        return blocks
    }
}

struct TableBlock: View {
    var rows: [[String]]

    var body: some View {
        let cols = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            let cell = c < row.count ? row[c] : ""
                            Text(MarkdownCache.inline(cell))
                                .font(r == 0 ? .callout.weight(.semibold) : .callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(r == 0 ? Theme.surfaceMuted : Color.clear)
                        }
                    }
                    if r < rows.count - 1 { Divider() }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .textSelection(.enabled)
    }
}

struct CodeBlock: View {
    @Environment(AppState.self) private var state
    var language: String
    var code: String
    @State private var copied = false

    private var previewable: Bool {
        ["html", "svg", "htm", "xml"].contains(language.lowercased())
            || code.range(of: "<html", options: .caseInsensitive) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if previewable {
                    Button { state.canvasHTML = code } label: {
                        Label("Preview", systemImage: "eye").font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                }
                Button {
                    copyToPasteboard(code)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border))
    }
}

/// Regexes compiled once. Regex literals in a loop were recompiled for every line on every render.
private enum Patterns {
    nonisolated(unsafe) static let heading = /^(#{1,6})\s+(.*)$/
    nonisolated(unsafe) static let rule = /^(-{3,}|\*{3,}|_{3,})$/
    nonisolated(unsafe) static let tableDivider = /^:?-{2,}:?$/
    nonisolated(unsafe) static let listItem = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/
}

/// Memoizes parsed Markdown so unchanged messages cost nothing to re-render, and a streaming
/// message only parses the paragraph that is still growing.
@MainActor
enum MarkdownCache {
    private static var blockCache: [String: [MarkdownView.Block]] = [:]
    private static var inlineCache: [String: AttributedString] = [:]

    private static var segmentCache: [String: [MarkdownView.Segment]] = [:]

    static func segments(_ text: String) -> [MarkdownView.Segment] {
        if let hit = segmentCache[text] { return hit }
        var out: [MarkdownView.Segment] = []
        var prose: [MarkdownView.Block] = []
        var n = 0
        func flush() {
            if !prose.isEmpty { out.append(.prose(prose, "\(text.hashValue)#\(n)")); n += 1; prose = [] }
        }
        for b in blocks(text) {
            switch b {
            case .code(let lang, let code): flush(); out.append(.code(lang, code))
            case .table(let rows): flush(); out.append(.table(rows))
            default: prose.append(b)
            }
        }
        flush()
        if segmentCache.count > 400 { segmentCache.removeAll(keepingCapacity: true) }
        segmentCache[text] = out
        return out
    }

    static func blocks(_ text: String) -> [MarkdownView.Block] {
        if let hit = blockCache[text] { return hit }
        let parsed = MarkdownView.parse(text)
        if blockCache.count > 400 { blockCache.removeAll(keepingCapacity: true) }
        blockCache[text] = parsed
        return parsed
    }

    static func inline(_ s: String) -> AttributedString {
        if let hit = inlineCache[s] { return hit }
        let attributed = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        if inlineCache.count > 4000 { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[s] = attributed
        return attributed
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
