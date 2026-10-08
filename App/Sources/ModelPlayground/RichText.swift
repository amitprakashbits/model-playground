import AppKit
import SwiftUI

/// Renders reply prose with AppKit's text system. It lays out long text far faster than one SwiftUI
/// `Text` per paragraph, and supports normal selection (drag across paragraphs, ⌘A, ⌘C).
struct SelectableText: NSViewRepresentable {
    var text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [.foregroundColor: NSColor(Theme.accent), .underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .cursor: NSCursor.pointingHand]
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.textStorage?.setAttributedString(text)
        context.coordinator.shown = text
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard context.coordinator.shown !== text else { return }
        context.coordinator.shown = text
        context.coordinator.heights.removeAll()
        view.textStorage?.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let width = max(40, (proposal.width ?? 600).rounded(.down))
        if let h = context.coordinator.heights[width] { return CGSize(width: width, height: h) }
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let h = ceil(layout.usedRect(for: container).height)
        context.coordinator.heights[width] = h
        return CGSize(width: width, height: h)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: NSAttributedString?
        var heights: [CGFloat: CGFloat] = [:]
    }
}

/// Converts the Markdown block model into attributed text for `SelectableText`.
@MainActor
enum RichTextBuilder {
    private static var cache: [String: NSAttributedString] = [:]

    static let body = NSFont(descriptor: NSFont.systemFont(ofSize: 15.5).fontDescriptor.withDesign(.serif)!, size: 15.5)!
    static let compact = NSFont.systemFont(ofSize: 14)

    static func build(_ blocks: [MarkdownView.Block], source: String, serif: Bool) -> NSAttributedString {
        let key = (serif ? "s|" : "c|") + source
        if let hit = cache[key] { return hit }
        let base = serif ? body : compact
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            switch block {
            case .heading(let level, let s):
                let size: CGFloat = level == 1 ? 22 : level == 2 ? 19 : 16.5
                let font = NSFont(descriptor: NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.serif)!, size: size)!
                out.append(inline(s, font: font, paragraph: paragraph(spacingBefore: 6, after: 6)))
            case .paragraph(let s):
                out.append(inline(s, font: base, paragraph: paragraph(after: 10, lineSpacing: 4)))
            case .list(let items, let ordered):
                for (n, item) in items.enumerated() {
                    if n > 0 { out.append(NSAttributedString(string: "\n")) }
                    let indent = CGFloat(item.indent) * 18
                    let p = paragraph(after: n == items.count - 1 ? 10 : 4, lineSpacing: 3)
                    p.firstLineHeadIndent = indent
                    p.headIndent = indent + 22
                    p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
                    let marker = NSAttributedString(string: (ordered ? "\(n + 1)." : "•") + "\t",
                                                    attributes: [.font: base, .foregroundColor: NSColor(Theme.secondaryText), .paragraphStyle: p])
                    out.append(marker)
                    out.append(inline(item.text, font: base, paragraph: p))
                }
            case .quote(let s):
                let p = paragraph(after: 10, lineSpacing: 3)
                p.firstLineHeadIndent = 14
                p.headIndent = 14
                out.append(inline(s, font: base, paragraph: p, color: NSColor(Theme.secondaryText)))
            case .rule:
                out.append(NSAttributedString(string: "———", attributes: [.foregroundColor: NSColor(Theme.border), .font: base]))
            case .code, .table:
                break  // rendered as separate SwiftUI views
            }
        }
        if cache.count > 300 { cache.removeAll(keepingCapacity: true) }
        cache[key] = out
        return out
    }

    private static func paragraph(spacingBefore: CGFloat = 0, after: CGFloat, lineSpacing: CGFloat = 2) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = after
        p.lineSpacing = lineSpacing
        return p
    }

    /// Applies inline Markdown (bold, italic, code, links) by reading the parsed presentation intents.
    private static func inline(_ s: String, font: NSFont, paragraph: NSParagraphStyle, color: NSColor = NSColor(Theme.text)) -> NSAttributedString {
        let parsed = MarkdownCache.inline(s)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var f = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    f = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(traits)), size: f.pointSize) ?? f
                }
                if intent.contains(.code) {
                    f = NSFont.monospacedSystemFont(ofSize: f.pointSize * 0.88, weight: .regular)
                    attrs[.backgroundColor] = NSColor(Theme.codeBackground)
                }
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link }
            attrs[.font] = f
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}
