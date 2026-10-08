import SwiftUI

struct StudioView: View {
    @Environment(AppState.self) private var state
    @State private var focused: Artboard?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { form.padding(18) }
                .frame(width: 330)
                .background(Theme.sidebar.opacity(0.5))
            Divider()
            VStack(spacing: 0) {
                canvasHeader
                Divider()
                canvas
            }
        }
        .background(Theme.background)
        .navigationTitle("")
        .sheet(item: $focused) { board in ArtboardDetail(board: board) }
    }

    // MARK: Form

    private var form: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Design studio").font(.system(size: 24, design: .serif))
                Text("Describe a product once, pick a design system, and generate matching pages on one canvas.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            field("Brand name") {
                TextField("Brand", text: $state.studio.brand).textFieldStyle(.roundedBorder)
            }
            field("Website / product brief") {
                TextEditor(text: $state.studio.brief)
                    .font(.callout)
                    .frame(height: 96)
                    .padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            }
            field("Design system") {
                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(DesignSystem.styles, id: \.0) { style, _ in
                            Button(style) { state.studio.style = style }
                                .buttonStyle(PillButtonStyle(prominent: state.studio.style == style))
                        }
                    }
                    Text(state.studio.styleDescription).font(.caption).foregroundStyle(Theme.secondaryText)
                    HStack {
                        Text("Primary color")
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: NSColor(hexString: state.studio.primaryHex) ?? .systemIndigo) },
                            set: { state.studio.primaryHex = NSColor($0).hexString }
                        ), supportsOpacity: false)
                        .labelsHidden()
                        Text(state.studio.primaryHex).font(.caption.monospaced()).foregroundStyle(Theme.secondaryText)
                    }
                    HStack(spacing: 6) {
                        ForEach(["#6366F1", "#0EA5E9", "#10B981", "#F59E0B", "#EF4444", "#EC4899", "#C96442", "#111827"], id: \.self) { hex in
                            Button { state.studio.primaryHex = hex } label: {
                                Circle().fill(Color(nsColor: NSColor(hexString: hex) ?? .gray)).frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Theme.text, lineWidth: state.studio.primaryHex == hex ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Picker("Font", selection: $state.studio.font) {
                        ForEach(DesignSystem.fonts, id: \.0) { f in Text(f.0).tag(f.0) }
                    }
                    LabeledSlider(title: "Corner radius", value: $state.studio.radius, range: 0...28, step: 1, help: "Applied to cards, buttons and inputs")
                }
            }
            field("Artboards") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(Artboard.all) { b in
                        Toggle(isOn: Binding(
                            get: { state.studioArtboards.contains(b.id) },
                            set: { on in
                                if on { state.studioArtboards.append(b.id) } else { state.studioArtboards.removeAll { $0 == b.id } }
                            }
                        )) {
                            Label(b.title, systemImage: b.icon).font(.callout)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            field("Model") {
                VStack(alignment: .leading, spacing: 6) {
                    ModelPicker(selection: state.studioSelection ?? state.designModel) { state.studioSelection = $0 }
                    let name = (state.studioSelection ?? state.designModel)?.model.name ?? ""
                    if ["WEBGEN", "UIGEN", "OmniCoder"].contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                        Label("Design-tuned model", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    } else {
                        Text("Tip: WEBGEN-4B (Design family in the library) is fine-tuned for web design.")
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            if state.isDesigning {
                Button(action: state.stopStudio) { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.pill)
            } else {
                Button(action: state.runStudio) {
                    Label("Generate \(state.studioArtboards.count) artboard\(state.studioArtboards.count == 1 ? "" : "s")", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pillProminent)
                .disabled(state.studioArtboards.isEmpty || state.studio.brief.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            content()
        }
    }

    // MARK: Canvas

    private var boards: [Artboard] { Artboard.all.filter { state.studioArtboards.contains($0.id) || state.studioResults[$0.id] != nil } }

    private var canvasHeader: some View {
        @Bindable var state = state
        let done = state.studioResults.values.filter { $0.html != nil }.count
        return HStack(spacing: 12) {
            Circle().fill(Color(nsColor: NSColor(hexString: state.studio.primaryHex) ?? .gray)).frame(width: 14, height: 14)
            Text(state.studio.brand).font(.headline)
            Text("\(state.studio.style) · \(state.studio.font) · \(Int(state.studio.radius))px").font(.caption).foregroundStyle(Theme.secondaryText)
            Spacer()
            if state.isDesigning { SparkleSpinner() }
            Text("\(done) of \(boards.count) ready").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
            Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.secondaryText)
            Slider(value: $state.studioZoom, in: 0.2...0.6).frame(width: 120)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.secondaryText)
            Button {
                let url = AppState.designsFolder.appendingPathComponent(state.studio.slug)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            } label: { Label("Open folder", systemImage: "folder") }
                .buttonStyle(.pill)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var canvas: some View {
        ScrollView([.horizontal, .vertical]) {
            if boards.isEmpty {
                EmptyState(icon: "paintbrush.pointed", title: "Your canvas", message: "Choose artboards on the left and press Generate.")
                    .frame(width: 600, height: 400)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 1280 * state.studioZoom + 24), spacing: 28, alignment: .top)],
                          alignment: .leading, spacing: 28) {
                    ForEach(boards) { b in
                        ArtboardCard(board: b, zoom: state.studioZoom) { focused = b }
                    }
                }
                .padding(28)
                .frame(minWidth: 900)
            }
        }
        .background(
            Canvas { ctx, size in
                // Dotted design-tool grid.
                let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.6, height: 1.6))
                for x in stride(from: 0, to: size.width, by: 22) {
                    for y in stride(from: 0, to: size.height, by: 22) {
                        ctx.fill(dot.offsetBy(dx: x, dy: y), with: .color(.gray.opacity(0.18)))
                    }
                }
            }
        )
    }
}

struct ArtboardCard: View {
    @Environment(AppState.self) private var state
    var board: Artboard
    var zoom: Double
    var open: () -> Void
    @State private var hovering = false

    private var result: ArtboardResult { state.studioResults[board.id] ?? ArtboardResult() }

    var body: some View {
        let w = board.width * zoom, h = board.height * zoom
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: board.icon).foregroundStyle(Theme.secondaryText)
                Text(board.title).font(.callout.weight(.semibold))
                if let st = result.stats {
                    Text(String(format: "%.0fs · %d tokens", st.totalSeconds, st.generationTokens))
                        .font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if result.html != nil {
                    Button(action: open) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.borderless).help("Open full size")
                }
            }
            .frame(width: w)
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white)
                if let html = result.html {
                    HTMLPreview(html: html, zoom: zoom)
                        .frame(width: w, height: h)
                        .allowsHitTesting(false)
                } else {
                    VStack(spacing: 8) {
                        switch result.phase {
                        case .running: SparkleSpinner()
                        case .waiting: Image(systemName: "clock").foregroundStyle(.gray)
                        default: Image(systemName: board.icon).font(.title).foregroundStyle(.gray.opacity(0.5))
                        }
                        Text(result.error ?? result.status ?? (result.phase == .idle ? "Not generated" : ""))
                            .font(.caption).foregroundStyle(result.error != nil ? .red : .gray)
                            .multilineTextAlignment(.center).padding(.horizontal, 12)
                    }
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(result.phase == .running ? Theme.accent : Theme.border, lineWidth: result.phase == .running ? 2 : 1))
            .shadow(color: .black.opacity(hovering ? 0.16 : 0.08), radius: hovering ? 18 : 10, y: hovering ? 8 : 4)
            .onTapGesture { if result.html != nil { open() } }
            .onHover { hovering = $0 }
        }
    }
}

struct ArtboardDetail: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var board: Artboard

    var body: some View {
        let result = state.studioResults[board.id] ?? ArtboardResult()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: board.icon)
                Text("\(state.studio.brand) · \(board.title)").font(.headline)
                Spacer()
                if let html = result.html {
                    Button { copyToPasteboard(html) } label: { Label("Copy HTML", systemImage: "doc.on.doc") }
                    if let path = result.savedPath {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                            Label("Show file", systemImage: "folder")
                        }
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                            Label("Open in browser", systemImage: "safari")
                        }
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            if let html = result.html {
                HTMLPreview(html: html)
                    .frame(width: board.width < 1000 ? board.width : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surfaceMuted)
            }
        }
        .frame(minWidth: 1000, minHeight: 720)
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#6366F1" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
