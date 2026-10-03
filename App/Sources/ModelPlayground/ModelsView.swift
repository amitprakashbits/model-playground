import AppKit
import SwiftUI

struct ModelsView: View {
    @Environment(AppState.self) private var state
    @State private var tab: Tab = .catalog
    @State private var filter = ""
    @State private var didPickTab = false

    enum Tab: String, CaseIterable, Identifiable {
        case installed = "Installed", catalog = "Discover", search = "Hugging Face"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Model library").font(.system(size: 28, design: .serif))
                    Spacer()
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases) { t in
                            Text(t == .installed ? "Installed (\(state.models.count))" : t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 380)
                }
                FolderCard()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 12)
            switch tab {
            case .installed: InstalledList(filter: filter)
            case .catalog: CatalogList(filter: filter)
            case .search: HFSearch()
            }
        }
        .background(Theme.background)
        .navigationTitle("")
        .searchable(text: $filter, placement: .toolbar, prompt: "Filter models")
        .toolbar {
            ToolbarItem {
                Button { Task { await state.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Rescan folders")
            }
        }
        .onAppear {
            if !didPickTab { tab = state.models.isEmpty ? .catalog : .installed; didPickTab = true }
        }
    }
}

struct FolderCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 14) {
            Image(systemName: "folder.fill").font(.system(size: 24)).foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Models folder").font(.caption).foregroundStyle(Theme.secondaryText)
                Text((state.modelsFolder as NSString).abbreviatingWithTildeInPath)
                    .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Toggle("Also include models in the Hugging Face cache", isOn: $state.includeHFCache)
                    .toggleStyle(.checkbox).font(.caption)
            }
            Spacer()
            if let s = state.system {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(s.freeDiskGb)) GB free").font(.callout.weight(.medium))
                    Text("\(Int(s.totalRamGb.rounded())) GB RAM").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                .padding(.trailing, 6)
            }
            Button("Change...") { state.chooseModelsFolder() }.buttonStyle(.pill)
            Button {
                let url = URL(fileURLWithPath: state.modelsFolder)
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.open(url)
            } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.pill)
                .help("Open in Finder")
        }
        .card()
    }
}

// MARK: - Installed

struct InstalledList: View {
    @Environment(AppState.self) private var state
    var filter: String
    @State private var toTrash: LocalModel?

    private var items: [LocalModel] {
        filter.isEmpty ? state.models : state.models.filter { $0.repoId.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        if state.models.isEmpty {
            EmptyState(icon: "square.stack.3d.up.slash", title: "No models yet",
                       message: "Download one from Discover, or choose a folder that already contains models.")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { m in row(m) }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
            }
            .confirmationDialog("Move \(toTrash?.name ?? "") to the Trash?", isPresented: .init(
                get: { toTrash != nil }, set: { if !$0 { toTrash = nil } }
            )) {
                Button("Move to Trash", role: .destructive) { if let m = toTrash { state.trash(m) } }
            } message: {
                Text("Frees \(toTrash?.sizeLabel ?? ""). You can restore it from the Trash.")
            }
        }
    }

    private func row(_ m: LocalModel) -> some View {
        HStack(spacing: 14) {
            ModelGlyph(name: m.name)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(m.name).font(.headline)
                    if state.loadedModel == m.name { Badge(text: "Loaded", color: .green, systemImage: "memorychip") }
                }
                Text(m.repoId).font(.caption).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 4) {
                    ForEach(m.engines, id: \.self) { EngineBadge(engine: $0) }
                    Badge(text: m.sizeLabel, systemImage: "internaldrive")
                    if m.context > 0 { Badge(text: "\(formatContext(m.context)) context", systemImage: "text.alignleft") }
                    Badge(text: m.quantized ? "Quantized" : "Full precision")
                    Badge(text: m.source == "hf-cache" ? "HF cache" : "Folder", systemImage: "folder")
                    FitBadge(fit: Fit.estimate(sizeGb: m.sizeGb, ramGb: state.ramGb), sizeGb: m.sizeGb)
                }
            }
            Spacer()
            Button("Chat") { state.newChat(with: ModelSelection(model: m, engine: m.engines[0])) }
                .buttonStyle(.pillProminent)
            Menu {
                ForEach(m.engines, id: \.self) { e in
                    Button("Chat using \(e == "airllm" ? "AirLLM" : "MLX")") { state.newChat(with: ModelSelection(model: m, engine: e)) }
                }
                Button("Add to Comparison") {
                    state.addCompare(ModelSelection(model: m, engine: m.engines[0]))
                    state.sidebarSelection = .compare
                }
                Button("Use as Judge") { state.judgeSelection = ModelSelection(model: m, engine: "mlx") }
                Divider()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.path)]) }
                if m.source == "folder" {
                    Button("Move to Trash...", role: .destructive) { toTrash = m }
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .card()
    }
}

struct ModelGlyph: View {
    var name: String
    var body: some View {
        let letter = name.first.map { String($0).uppercased() } ?? "?"
        let hue = Double(abs(name.hashValue % 360)) / 360
        Text(letter)
            .font(.system(size: 17, weight: .semibold, design: .serif))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color(hue: hue, saturation: 0.35, brightness: 0.62), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Catalog

struct CatalogList: View {
    @Environment(AppState.self) private var state
    var filter: String
    @State private var family = "All"

    private var families: [String] {
        var seen: [String] = []
        for e in state.catalog where !seen.contains(e.family) { seen.append(e.family) }
        return ["All"] + seen
    }

    private var items: [CatalogEntry] {
        state.catalog.filter { e in
            (family == "All" || e.family == family)
                && (filter.isEmpty || e.repoId.localizedCaseInsensitiveContains(filter) || e.family.localizedCaseInsensitiveContains(filter))
        }
    }

    private var recommended: [CatalogEntry] {
        let picks = ["mlx-community/Qwen3.5-9B-4bit", "mlx-community/Qwen3-4B-Instruct-2507-4bit",
                     "mlx-community/Qwen3-14B-4bit", "mlx-community/Mistral-Nemo-Instruct-2407-4bit"]
        return picks.compactMap { p in state.catalog.first { $0.repoId == p } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if filter.isEmpty && family == "All" && !recommended.isEmpty {
                    Text("Recommended for your Mac").font(.system(size: 18, design: .serif))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(recommended) { e in RecommendedCard(entry: e) }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(families, id: \.self) { f in
                            Button(f) { family = f }
                                .buttonStyle(PillButtonStyle(prominent: family == f))
                        }
                    }
                }
                LazyVStack(spacing: 8) {
                    ForEach(items) { e in CatalogRow(entry: e) }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
    }
}

struct RecommendedCard: View {
    @Environment(AppState.self) private var state
    var entry: CatalogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ModelGlyph(name: entry.name)
                Spacer()
                FitBadge(fit: Fit.estimate(sizeGb: entry.sizeGb, ramGb: state.ramGb), sizeGb: entry.sizeGb)
            }
            Text(entry.name.replacingOccurrences(of: "-4bit", with: "")).font(.headline).lineLimit(1)
            Text(entry.notes).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(2, reservesSpace: true)
            HStack(spacing: 4) {
                Badge(text: entry.params)
                Badge(text: String(format: "%.1f GB", entry.sizeGb))
                Badge(text: "\(formatContext(entry.context)) ctx")
            }
            DownloadButton(repoId: entry.repoId, convert: entry.needsConversion)
        }
        .card()
    }
}

struct CatalogRow: View {
    @Environment(AppState.self) private var state
    var entry: CatalogEntry

    var body: some View {
        HStack(spacing: 14) {
            ModelGlyph(name: entry.name)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.name).font(.headline)
                    Text(entry.params).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Badge(text: entry.family)
                }
                Text(entry.notes).font(.caption).foregroundStyle(Theme.secondaryText)
                HStack(spacing: 4) {
                    if entry.needsConversion {
                        Badge(text: "Converted to MLX", color: .blue, systemImage: "wand.and.stars")
                    } else {
                        EngineBadge(engine: entry.engine)
                    }
                    Badge(text: String(format: "%.1f GB", entry.sizeGb), systemImage: "arrow.down.circle")
                    Badge(text: "\(formatContext(entry.context)) context", systemImage: "text.alignleft")
                    if entry.engine == "airllm" {
                        // AirLLM keeps one layer in memory at a time; disk space is what matters.
                        let fitsDisk = entry.sizeGb < (state.system?.freeDiskGb ?? 0)
                        Badge(text: fitsDisk ? "Streams from disk" : "Needs \(Int(entry.sizeGb.rounded())) GB free disk",
                              color: fitsDisk ? .purple : .red, systemImage: "externaldrive")
                    } else {
                        FitBadge(fit: Fit.estimate(sizeGb: entry.installedSizeGb, ramGb: state.ramGb), sizeGb: entry.installedSizeGb)
                    }
                }
            }
            Spacer()
            DownloadButton(repoId: entry.repoId, convert: entry.needsConversion)
        }
        .card(padding: 12)
    }
}

struct DownloadButton: View {
    @Environment(AppState.self) private var state
    var repoId: String
    var convert = false

    var body: some View {
        if state.isInstalled(repoId) {
            Button {
                if let m = state.installedModel(repoId) {
                    state.newChat(with: ModelSelection(model: m, engine: m.engines[0]))
                }
            } label: { Label("Chat", systemImage: "bubble.left") }
                .buttonStyle(.pill)
        } else if let job = state.activeDownload(repoId), job.status == "converting" {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView().controlSize(.small)
                Text("Converting to 4-bit MLX...").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
        } else if let job = state.activeDownload(repoId), job.isActive {
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: job.fraction).frame(width: 150).tint(Theme.accent)
                Text(job.total > 0
                     ? "\(ByteCountFormatter.string(fromByteCount: job.downloaded, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: job.total, countStyle: .file))"
                     : "Starting...")
                    .font(.caption2).foregroundStyle(Theme.secondaryText).monospacedDigit()
            }
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                if convert {
                    Button { state.convert(repoId) } label: { Label("Download & convert", systemImage: "wand.and.stars") }
                        .buttonStyle(.pillProminent)
                        .help("Downloads the full-precision weights and quantizes them to a 4-bit MLX model")
                } else {
                    Button { state.download(repoId) } label: { Label("Download", systemImage: "arrow.down") }
                        .buttonStyle(.pillProminent)
                }
                if let job = state.activeDownload(repoId), job.status == "error" {
                    Text("Failed: \(job.error ?? "")").font(.caption2).foregroundStyle(.red).lineLimit(2)
                        .frame(maxWidth: 220, alignment: .trailing)
                        .help(job.error ?? "")
                }
            }
        }
    }
}

// MARK: - Hugging Face search

struct HFSearch: View {
    @Environment(AppState.self) private var state
    @State private var query = ""
    @State private var mlxOnly = true
    @State private var results: [SearchResult] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                    TextField("Search Hugging Face, e.g. qwen3.5, gemma 4, llama 70b...", text: $query)
                        .textFieldStyle(.plain)
                        .onSubmit(run)
                }
                .padding(9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                Toggle("MLX-ready only", isOn: $mlxOnly).toggleStyle(.checkbox)
                    .help("Only show mlx-community conversions, which run with the MLX engine")
                Button("Search", action: run).buttonStyle(.pillProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)
            if !mlxOnly {
                Text("Full-precision repos can be downloaded and converted to 4-bit MLX in one step, if mlx-lm supports their architecture.")
                    .font(.caption).foregroundStyle(Theme.secondaryText).padding(.bottom, 6)
            }
            if loading {
                ProgressView().frame(maxHeight: .infinity)
            } else if let error {
                EmptyState(icon: "wifi.exclamationmark", title: "Search failed", message: error)
            } else if results.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "Search Hugging Face",
                           message: "Thousands of open models. On a 16 GB Mac, look for 3-bit or 4-bit versions under about 9 GB.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(results) { r in
                            HStack(spacing: 14) {
                                ModelGlyph(name: r.repoId.split(separator: "/").last.map(String.init) ?? r.repoId)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.repoId.split(separator: "/").last.map(String.init) ?? r.repoId).font(.headline)
                                    Text(r.repoId).font(.caption).foregroundStyle(Theme.secondaryText)
                                    HStack(spacing: 4) {
                                        Badge(text: formatCount(r.downloads), systemImage: "arrow.down")
                                        Badge(text: formatCount(r.likes), systemImage: "heart")
                                        if let q = quantLabel(r.repoId) { Badge(text: q, color: .blue) }
                                    }
                                }
                                Spacer()
                                if isMLX(r.repoId) {
                                    DownloadButton(repoId: r.repoId)
                                } else {
                                    DownloadButton(repoId: r.repoId, convert: true)
                                }
                            }
                            .card(padding: 12)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 20)
                }
            }
        }
        .task { if results.isEmpty { run() } }
    }

    private func isMLX(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.hasPrefix("mlx-community/") || l.contains("mlx")
    }

    private func quantLabel(_ id: String) -> String? {
        let l = id.lowercased()
        for q in ["2bit", "3bit", "4bit", "5bit", "6bit", "8bit", "bf16", "fp16", "mxfp4"] where l.contains(q) { return q }
        return nil
    }

    private func run() {
        loading = true
        error = nil
        Task {
            do { results = try await state.api.search(query, mlxOnly: mlxOnly) }
            catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
