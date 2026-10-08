import SwiftUI
import WebKit

private var extractCache: [String: String?] = [:]

/// Pulls a renderable page out of a model reply: the last ```html / ```svg block, or a raw document.
/// Memoized, because message rows ask for it on every render.
@MainActor
func extractHTML(_ text: String) -> String? {
    if let hit = extractCache[text] { return hit }
    let found = findHTML(text)
    if extractCache.count > 500 { extractCache.removeAll(keepingCapacity: true) }
    extractCache[text] = found
    return found
}

private func findHTML(_ text: String) -> String? {
    let answer = splitReasoning(text).answer
    var best: String?
    let parts = answer.components(separatedBy: "```")
    for i in stride(from: 1, to: parts.count, by: 2) {
        var lines = parts[i].components(separatedBy: "\n")
        let lang = lines.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        lines.removeFirst()
        let code = lines.joined(separator: "\n")
        let looksHTML = code.range(of: "<html", options: .caseInsensitive) != nil
            || code.range(of: "<!doctype", options: .caseInsensitive) != nil
            || code.range(of: "<svg", options: .caseInsensitive) != nil
        if ["html", "svg", "xml", "htm"].contains(lang) || (lang.isEmpty && looksHTML) {
            best = code
        }
    }
    if best == nil, let start = answer.range(of: "<!doctype html", options: .caseInsensitive)
        ?? answer.range(of: "<html", options: .caseInsensitive) {
        best = String(answer[start.lowerBound...])
    }
    guard let html = best, html.count > 20 else { return nil }
    return html
}

/// Sandboxed web view for previewing generated pages. Links never navigate away from the preview.
/// Keeps sloppy generated markup presentable: unsized SVG icons otherwise grow to fill their container.
let previewSafetyCSS = "<style id='mp-safety'>svg:not([width]):not([class*='w-']):not([style*='width']){max-width:1.75em;max-height:1.75em}img{max-width:100%;height:auto}</style>"
    + revealScript

/// Generated pages often hide content until a scroll script reveals it. If the reply was cut off
/// before that script, or the script never fires in a preview, show the content anyway.
private let revealScript = """
<script id='mp-reveal'>addEventListener('load',function(){setTimeout(function(){
var show=['is-visible','visible','in-view','show','active','animate-in','aos-animate','revealed','appear'];
document.body.querySelectorAll('[class*="anim"],[class*="reveal"],[class*="fade"],[class*="scroll-"],[data-aos],[data-animate],[data-animate-element],[data-reveal]').forEach(function(el){
show.forEach(function(c){el.classList.add(c)});
var cs=getComputedStyle(el);if(parseFloat(cs.opacity)<0.05){el.style.opacity='1'}});
},700)});</script>
"""

/// Inserts extra markup right after <head> (or at the top when there is no head).
func injectIntoHead(_ html: String, _ extra: String) -> String {
    if let r = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
        var out = html
        out.insert(contentsOf: extra, at: r.upperBound)
        return out
    }
    return extra + html
}

struct HTMLPreview: NSViewRepresentable {
    var html: String
    var zoom: CGFloat = 1

    /// The most recently created preview, so the self-test can verify what actually rendered.
    @MainActor static weak var lastView: WKWebView?
    @MainActor static var lastLoadFinished = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        HTMLPreview.lastView = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.pageZoom != zoom { view.pageZoom = zoom }
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        HTMLPreview.lastLoadFinished = false
        let page = html.range(of: "<svg", options: .caseInsensitive) != nil && html.range(of: "<html", options: .caseInsensitive) == nil
            ? "<html><body style='margin:0;display:grid;place-items:center;min-height:100vh;background:#fff'>\(html)</body></html>"
            : html
        view.pageZoom = zoom
        view.loadHTMLString(injectIntoHead(page, previewSafetyCSS), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { HTMLPreview.lastLoadFinished = true }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow the initial load and in-page anchors; open nothing else.
            if action.navigationType == .other || action.request.url?.scheme == "about" || action.request.url?.fragment != nil {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

/// Right-hand canvas that shows the latest generated page.
struct CanvasPane: View {
    @Environment(AppState.self) private var state
    var html: String
    @State private var device: Device = .desktop

    enum Device: String, CaseIterable { case desktop = "Desktop", tablet = "Tablet", phone = "Phone" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush.pointed.fill").foregroundStyle(Theme.accent)
                Text("Canvas").font(.headline)
                Spacer()
                Picker("", selection: $device) {
                    ForEach(Device.allCases, id: \.self) { d in Text(d.rawValue).tag(d) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                Button { copyToPasteboard(html) } label: { Image(systemName: "doc.on.doc") }.help("Copy HTML")
                Button { saveHTML() } label: { Image(systemName: "square.and.arrow.down") }.help("Save as .html")
                Button { state.canvasHTML = nil } label: { Image(systemName: "xmark") }.help("Close canvas")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            GeometryReader { geo in
                let width: CGFloat = device == .desktop ? geo.size.width : (device == .tablet ? min(820, geo.size.width) : min(390, geo.size.width))
                HTMLPreview(html: html)
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: device == .desktop ? 0 : 14))
                    .overlay(RoundedRectangle(cornerRadius: device == .desktop ? 0 : 14).stroke(device == .desktop ? Color.clear : Theme.border))
                    .padding(.vertical, device == .desktop ? 0 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.surfaceMuted.opacity(0.5))
        }
        .background(Theme.surface)
    }

    private func saveHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "design.html"
        if panel.runModal() == .OK, let url = panel.url { try? html.write(to: url, atomically: true, encoding: .utf8) }
    }
}
