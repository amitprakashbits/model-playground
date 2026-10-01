import AppKit
import Foundation
import Observation
import PDFKit
import UniformTypeIdentifiers

enum ServerState: Equatable {
    case stopped, starting, running, failed(String)
}

enum CompareTab: String, CaseIterable, Identifiable {
    case answers = "Answers", stats = "Stats", quality = "Quality"
    var id: String { rawValue }
}

enum SidebarItem: Hashable {
    case chat(UUID)
    case compare
    case benchmarks
    case leaderboard
    case models
    case settings
}

struct CompareColumn: Identifiable, Hashable {
    var id = UUID()
    var selection: ModelSelection
    var output = ""
    var stats: GenerationStats?
    var status: String?
    var error: String?
    var phase: Phase = .idle
    var isBest = false
    var score: JudgeScore?
    var promptTokenCount: Int?

    enum Phase: Hashable { case idle, waiting, running, done }

    var answer: String { splitReasoning(output).answer }
    var words: Int { wordCount(answer) }
}

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    static let isSelfTest = CommandLine.arguments.contains("--selftest")
    private static let defaults: UserDefaults = isSelfTest ? UserDefaults(suiteName: "local.modelplayground.selftest")! : .standard

    // MARK: Settings (persisted)

    var modelsFolder: String = AppState.defaults.string(forKey: "modelsFolder")
        ?? (NSHomeDirectory() + "/ModelPlayground/models") {
        didSet { Self.defaults.set(modelsFolder, forKey: "modelsFolder"); Task { await refreshModels(); await refreshSystem() } }
    }
    var pythonPath: String = AppState.defaults.string(forKey: "pythonPath") ?? AppState.defaultPython() {
        didSet { Self.defaults.set(pythonPath, forKey: "pythonPath") }
    }
    /// 0 picks a free port automatically on every launch.
    var preferredPort: Int = AppState.defaults.object(forKey: "port") as? Int ?? 0 {
        didSet { Self.defaults.set(preferredPort, forKey: "port") }
    }
    var includeHFCache: Bool = AppState.defaults.object(forKey: "includeHFCache") as? Bool ?? true {
        didSet { Self.defaults.set(includeHFCache, forKey: "includeHFCache"); Task { await refreshModels() } }
    }
    var params: GenParams = AppState.loadParams() {
        didSet { if let d = try? JSONEncoder().encode(params) { Self.defaults.set(d, forKey: "params") } }
    }

    // MARK: Data

    var port = 0
    var serverState: ServerState = .stopped
    var serverLog = ""
    var loadedModel: String?
    var models: [LocalModel] = []
    var catalog: [CatalogEntry] = []
    var downloads: [DownloadJob] = []
    var system: SystemInfo?
    var sessions: [ChatSession] = []
    var runs: [RunRecord] = []
    var sidebarSelection: SidebarItem? = .models
    var drafts: [UUID: String] = [:]
    var pendingAttachments: [UUID: [Attachment]] = [:]

    var compareColumns: [CompareColumn] = []
    var compareTab: CompareTab = .answers
    var comparePrompt = ""
    var lastComparePrompt = ""
    var isComparing = false
    var judgeSelection: ModelSelection?
    var isJudging = false
    var judgeStatus: String?
    var generatingSession: UUID?
    var isInstallingEnv = false

    // Blind arena: hide model names in Compare until you vote.
    var compareBlind = false
    var compareRevealed = false

    // Benchmarks
    var benchmarkRuns: [BenchmarkRun] = []
    var benchSelections: [ModelSelection] = []
    var benchSuites: Set<String> = ["quick", "needle"]
    var benchMaxContext = 16000
    var isBenchmarking = false
    var benchStatus: String?

    func displayName(_ col: CompareColumn) -> String {
        guard compareBlind && !compareRevealed,
              let i = compareColumns.firstIndex(where: { $0.id == col.id }) else { return col.selection.shortLabel }
        return "Model \(Character(UnicodeScalar(65 + i)!))"
    }

    private var process: Process?
    private var downloadPoller: Task<Void, Never>?
    private var restarts = 0

    var api: APIClient { APIClient(port: port) }

    var selections: [ModelSelection] {
        models.flatMap { m in m.engines.map { ModelSelection(model: m, engine: $0) } }
    }

    var ramGb: Double { system?.totalRamGb ?? 16 }

    private static func loadParams() -> GenParams {
        if let d = defaults.data(forKey: "params"), let p = try? JSONDecoder().decode(GenParams.self, from: d) { return p }
        return GenParams()
    }

    static var managedVenv: String { dataDirectory.appendingPathComponent("venv").path }

    private static func defaultPython() -> String {
        let candidates = [managedVenv + "/bin/python", NSHomeDirectory() + "/airllm/.venv/bin/python"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(isSelfTest ? "ModelPlayground-SelfTest" : "ModelPlayground", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Lifecycle

    func boot() async {
        loadSessions()
        loadRuns()
        loadBenchmarks()
        if sessions.isEmpty { newChat(select: false) }
        await startServer()
        if serverState == .running {
            await refreshAll()
            if let first = sessions.first {
                sidebarSelection = models.isEmpty ? .models : .chat(first.id)
                if first.selection == nil, let sel = defaultSelection { setSelection(sel, for: first.id) }
            }
        }
    }

    func startServer() async {
        port = preferredPort > 0 ? preferredPort : Self.findFreePort()
        if preferredPort > 0, (try? await api.health()) != nil {
            serverState = .running  // our backend is already running on the fixed port
            return
        }
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            serverState = .failed("Python environment not found. Install it with one click below, or choose an existing one.")
            return
        }
        guard let script = serverScriptPath() else {
            serverState = .failed("server.py is missing from the app bundle. Rebuild the app.")
            return
        }
        serverState = .starting
        log("starting backend on port \(port) with \(pythonPath)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [script, "--port", String(port)]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            guard !s.isEmpty else { return }
            Task { @MainActor in AppState.shared.appendLog(s) }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in AppState.shared.backendExited(proc, code: proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
        } catch {
            serverState = .failed("Could not launch Python: \(error.localizedDescription)")
            return
        }
        for _ in 0..<180 {
            try? await Task.sleep(for: .milliseconds(500))
            if case .failed = serverState { return }
            if (try? await api.health()) != nil {
                serverState = .running
                log("backend ready")
                return
            }
        }
        serverState = .failed("The backend did not respond within 90 seconds. Check the log in Settings.")
    }

    private func backendExited(_ proc: Process, code: Int32) {
        log("backend exited with code \(code)")
        guard proc === process, serverState != .stopped else { return }
        process = nil
        if serverState == .running && restarts < 2 {
            // Crashed while in use (often out of memory): restart automatically.
            restarts += 1
            serverState = .starting
            failInFlight("The backend crashed, possibly out of memory. It was restarted; try a smaller model.")
            Task { await startServer(); if serverState == .running { await refreshAll() } }
        } else {
            serverState = .failed("The backend stopped (exit code \(code)). Check the log in Settings.")
        }
    }

    private func failInFlight(_ message: String) {
        for si in sessions.indices {
            for mi in sessions[si].messages.indices where sessions[si].messages[mi].isStreaming {
                sessions[si].messages[mi].isStreaming = false
                sessions[si].messages[mi].status = nil
                sessions[si].messages[mi].error = message
            }
        }
        generatingSession = nil
    }

    func stopServer() {
        serverState = .stopped
        process?.terminate()
        process = nil
    }

    func restartServer() async {
        stopServer()
        restarts = 0
        try? await Task.sleep(for: .milliseconds(600))
        await startServer()
        if serverState == .running { await refreshAll() }
    }

    func appendLog(_ s: String) {
        serverLog += s
        if serverLog.count > 200_000 { serverLog = String(serverLog.suffix(100_000)) }
        if Self.isSelfTest { FileHandle.standardError.write(Data(s.utf8)) }
    }

    func log(_ msg: String) {
        appendLog("[app] \(msg)\n")
    }

    private func serverScriptPath() -> String? {
        if let url = Bundle.main.url(forResource: "server", withExtension: "py") { return url.path }
        // Running from `swift run`: fall back to the repo layout.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("backend/server.py").path
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    static func findFreePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 8765 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, len) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : 8765
    }

    /// Creates a private Python environment with everything the backend needs.
    func installEnvironment() {
        guard !isInstallingEnv else { return }
        isInstallingEnv = true
        let venv = Self.managedVenv
        let script = """
        set -e
        PY=$(command -v python3.12 || command -v python3.13 || command -v python3)
        echo "Using $PY"
        "$PY" -m venv "\(venv)"
        "\(venv)/bin/pip" install --upgrade pip
        "\(venv)/bin/pip" install mlx-lm airllm fastapi uvicorn psutil
        echo "Environment ready."
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            if !s.isEmpty { Task { @MainActor in AppState.shared.appendLog(s) } }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in
                let state = AppState.shared
                state.isInstallingEnv = false
                if proc.terminationStatus == 0 {
                    state.pythonPath = venv + "/bin/python"
                    await state.restartServer()
                } else {
                    state.serverState = .failed("Installing the Python environment failed. See the log below.")
                }
            }
        }
        log("installing Python environment into \(venv)")
        do { try p.run() } catch {
            isInstallingEnv = false
            serverState = .failed("Could not run the installer: \(error.localizedDescription)")
        }
    }

    // MARK: Refresh

    func refreshAll() async {
        async let c: () = refreshCatalog()
        async let m: () = refreshModels()
        async let s: () = refreshSystem()
        async let d: () = refreshDownloads()
        _ = await (c, m, s, d)
    }

    func refreshCatalog() async {
        if let c = try? await api.catalog() { catalog = c }
    }

    func refreshModels() async {
        guard serverState == .running else { return }
        if let m = try? await api.models(folder: modelsFolder, includeHFCache: includeHFCache) {
            models = m.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        await refreshLoaded()
    }

    func refreshLoaded() async {
        if let h = try? await api.health() {
            loadedModel = h.loaded.flatMap { key in models.first { $0.path == key[1] }?.name ?? URL(fileURLWithPath: key[1]).lastPathComponent }
        }
    }

    func refreshSystem() async {
        if let s = try? await api.system(folder: modelsFolder) { system = s }
    }

    func refreshDownloads() async {
        if let d = try? await api.downloads() { downloads = d }
    }

    func isInstalled(_ repoId: String) -> Bool { models.contains { $0.repoId == repoId } }

    func activeDownload(_ repoId: String) -> DownloadJob? {
        downloads.last { $0.repoId == repoId && ($0.isActive || $0.status == "error") }
    }

    /// The largest installed MLX model, used as the default judge and chat model.
    var largestModel: ModelSelection? {
        selections.filter { $0.engine == "mlx" }.max { $0.model.sizeBytes < $1.model.sizeBytes }
    }

    var defaultSelection: ModelSelection? { largestModel ?? selections.first }

    // MARK: Downloads

    func download(_ repoId: String) {
        Task {
            do {
                try FileManager.default.createDirectory(atPath: modelsFolder, withIntermediateDirectories: true)
                _ = try await api.download(repoId: repoId, folder: modelsFolder)
                await refreshDownloads()
                pollDownloads()
            } catch {
                presentError("Download failed", error.localizedDescription)
            }
        }
    }

    private func pollDownloads() {
        guard downloadPoller == nil else { return }
        downloadPoller = Task {
            while !Task.isCancelled {
                await refreshDownloads()
                if !downloads.contains(where: { $0.isActive }) { break }
                try? await Task.sleep(for: .seconds(1))
            }
            await refreshModels()
            await refreshSystem()
            downloadPoller = nil
        }
    }

    func trash(_ model: LocalModel) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: model.path), resultingItemURL: nil)
            Task { await refreshModels(); await refreshSystem() }
        } catch {
            presentError("Could not move to Trash", error.localizedDescription)
        }
    }

    func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where models are stored and downloaded"
        panel.directoryURL = URL(fileURLWithPath: modelsFolder)
        if panel.runModal() == .OK, let url = panel.url { modelsFolder = url.path }
    }

    func choosePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the python executable inside a virtual environment with mlx-lm installed"
        panel.directoryURL = URL(fileURLWithPath: pythonPath).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            pythonPath = url.path
            Task { await restartServer() }
        }
    }

    func presentError(_ title: String, _ message: String) {
        if Self.isSelfTest { log("ERROR \(title): \(message)"); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Attachments

    func pickAttachments(for sessionId: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Attach text, code, Markdown or PDF files"
        if panel.runModal() == .OK { addAttachments(panel.urls, to: sessionId) }
    }

    func addAttachments(_ urls: [URL], to sessionId: UUID) {
        for url in urls {
            do {
                let att = try Self.readAttachment(url)
                pendingAttachments[sessionId, default: []].append(att)
            } catch {
                presentError("Couldn't attach \(url.lastPathComponent)", error.localizedDescription)
            }
        }
    }

    static func readAttachment(_ url: URL) throws -> Attachment {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url), let text = doc.string, !text.isEmpty else {
                throw APIError(message: "No text could be extracted from this PDF.")
            }
            return Attachment(name: url.lastPathComponent, content: text, sizeBytes: size)
        }
        guard size <= 4_000_000 else { throw APIError(message: "Files larger than 4 MB aren't supported.") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.contains("\u{0}") else {
            throw APIError(message: "Only text files can be attached.")
        }
        return Attachment(name: url.lastPathComponent, content: text, sizeBytes: size)
    }

    // MARK: Chat

    @discardableResult
    func newChat(with selection: ModelSelection? = nil, select: Bool = true) -> UUID {
        if let first = sessions.first, first.messages.isEmpty {
            // Reuse an untouched chat instead of stacking empty ones.
            if let selection { setSelection(selection, for: first.id) }
            if select { sidebarSelection = .chat(first.id) }
            return first.id
        }
        var s = ChatSession()
        s.selection = selection ?? sessions.first?.selection ?? defaultSelection
        sessions.insert(s, at: 0)
        if select { sidebarSelection = .chat(s.id) }
        saveSessions()
        return s.id
    }

    func deleteChat(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if sessions.isEmpty { newChat(select: false) }
        if case .chat(let cur) = sidebarSelection, cur == id { sidebarSelection = .chat(sessions[0].id) }
        saveSessions()
    }

    func renameChat(_ id: UUID, to title: String) {
        guard let i = index(of: id) else { return }
        sessions[i].title = title
        saveSessions()
    }

    func setSelection(_ sel: ModelSelection, for id: UUID) {
        guard let i = index(of: id) else { return }
        sessions[i].selection = sel
        saveSessions()
    }

    func index(of id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }

    func send(_ text: String, in sessionId: UUID) {
        guard let i = index(of: sessionId), let sel = sessions[i].selection, generatingSession == nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = pendingAttachments[sessionId] ?? []
        guard !trimmed.isEmpty || !atts.isEmpty else { return }
        if sessions[i].messages.isEmpty {
            sessions[i].title = trimmed.isEmpty ? (atts.first?.name ?? "New chat") : String(trimmed.prefix(60))
        }
        sessions[i].messages.append(ChatMessage(role: "user", content: trimmed, attachments: atts))
        pendingAttachments[sessionId] = nil
        drafts[sessionId] = nil
        runAssistant(sessionId: sessionId, selection: sel)
    }

    func regenerate(in sessionId: UUID) {
        guard let i = index(of: sessionId), let sel = sessions[i].selection, generatingSession == nil else { return }
        if sessions[i].messages.last?.role == "assistant" { sessions[i].messages.removeLast() }
        runAssistant(sessionId: sessionId, selection: sel)
    }

    private func runAssistant(sessionId: UUID, selection: ModelSelection) {
        guard let i = index(of: sessionId) else { return }
        // Send prior turns without their reasoning to save context.
        let history = sessions[i].messages.filter { $0.error == nil && !($0.role == "assistant" && $0.content.isEmpty) }.map { m -> ChatMessage in
            var m = m
            if m.role == "assistant" { m.content = splitReasoning(m.content).answer }
            return m
        }
        var reply = ChatMessage(role: "assistant", content: "", modelLabel: selection.shortLabel, isStreaming: true)
        reply.status = "Starting..."
        sessions[i].messages.append(reply)
        sessions[i].updated = Date()
        let replyId = reply.id
        generatingSession = sessionId

        Task {
            @MainActor func update(_ f: (inout ChatMessage) -> Void) {
                guard let si = index(of: sessionId), let mi = sessions[si].messages.firstIndex(where: { $0.id == replyId }) else { return }
                f(&sessions[si].messages[mi])
            }
            var finalStats: GenerationStats?
            do {
                for try await ev in api.chat(selection: selection, messages: history, params: params) {
                    switch ev {
                    case .status(let s): update { $0.status = s }
                    case .loaded: update { $0.status = "Thinking..." }; loadedModel = selection.model.name
                    case .token(let t): update { $0.status = nil; $0.content += t }
                    case .done(let st): update { $0.stats = st }; finalStats = st
                    case .error(let e): update { $0.error = e }
                    case .score, .result: break
                    }
                }
            } catch {
                update { $0.error = Self.describe(error) }
            }
            update { $0.isStreaming = false; $0.status = nil }
            if let st = finalStats { recordRun(model: selection.shortLabel, engine: selection.engine, source: "chat", stats: st) }
            generatingSession = nil
            saveSessions()
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost, .networkConnectionLost: return "Lost connection to the backend."
            case .timedOut: return "The backend took too long to respond."
            default: break
            }
        }
        return error.localizedDescription
    }

    func stopGenerating() {
        Task { await api.stop() }
    }

    // MARK: Compare

    func addCompare(_ selection: ModelSelection) {
        guard compareColumns.count < 4, !compareColumns.contains(where: { $0.selection.id == selection.id }) else { return }
        compareColumns.append(CompareColumn(selection: selection))
    }

    func removeCompare(_ id: UUID) { compareColumns.removeAll { $0.id == id } }

    func markBest(_ id: UUID) {
        if compareBlind { compareRevealed = true }
        for i in compareColumns.indices { compareColumns[i].isBest = compareColumns[i].id == id && !compareColumns[i].isBest }
        // Credit the vote on the latest compare run of each model in this round.
        let names = Set(compareColumns.map(\.selection.shortLabel))
        let best = compareColumns.first(where: \.isBest)?.selection.shortLabel
        for name in names {
            if let ri = runs.lastIndex(where: { $0.source == "compare" && $0.model == name }) {
                runs[ri].wonVote = name == best
            }
        }
        saveRuns()
    }

    func runCompare() {
        let prompt = comparePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !compareColumns.isEmpty, !isComparing, !isJudging else { return }
        isComparing = true
        compareRevealed = false
        if compareBlind { compareColumns.shuffle() }  // hide which model is which
        lastComparePrompt = prompt
        comparePrompt = ""
        for i in compareColumns.indices {
            compareColumns[i].output = ""
            compareColumns[i].stats = nil
            compareColumns[i].error = nil
            compareColumns[i].isBest = false
            compareColumns[i].score = nil
            compareColumns[i].promptTokenCount = nil
            compareColumns[i].status = "Waiting for its turn..."
            compareColumns[i].phase = .waiting
        }
        let messages = [ChatMessage(role: "user", content: prompt)]
        Task {
            // How many tokens each model's tokenizer needs for the same prompt.
            if let tk = try? await api.tokenize(paths: compareColumns.map(\.selection.model.path), text: prompt) {
                for i in compareColumns.indices {
                    compareColumns[i].promptTokenCount = tk.counts[compareColumns[i].selection.model.path] ?? nil
                }
            }
            // Models run one after another: only one fits in memory at a time.
            for col in compareColumns.map(\.id) {
                guard isComparing else { break }
                @MainActor func update(_ f: (inout CompareColumn) -> Void) {
                    if let i = compareColumns.firstIndex(where: { $0.id == col }) { f(&compareColumns[i]) }
                }
                guard let sel = compareColumns.first(where: { $0.id == col })?.selection else { continue }
                update { $0.phase = .running; $0.status = "Starting..." }
                var finalStats: GenerationStats?
                do {
                    for try await ev in api.chat(selection: sel, messages: messages, params: params) {
                        switch ev {
                        case .status(let s): update { $0.status = s }
                        case .loaded: update { $0.status = "Thinking..." }; loadedModel = sel.model.name
                        case .token(let t): update { $0.status = nil; $0.output += t }
                        case .done(let st): update { $0.stats = st }; finalStats = st
                        case .error(let e): update { $0.error = e }
                        case .score, .result: break
                        }
                    }
                } catch {
                    update { $0.error = Self.describe(error) }
                }
                update { $0.phase = .done; $0.status = nil }
                if let st = finalStats { recordRun(model: sel.shortLabel, engine: sel.engine, source: "compare", stats: st) }
            }
            for i in compareColumns.indices where compareColumns[i].phase == .waiting {
                compareColumns[i].phase = .idle
                compareColumns[i].status = nil
            }
            isComparing = false
        }
    }

    func stopCompare() {
        isComparing = false
        isJudging = false
        Task { await api.stop() }
    }

    var canJudge: Bool {
        !isComparing && !isJudging && compareColumns.contains { $0.phase == .done && !$0.answer.isEmpty }
    }

    func runJudge() {
        guard canJudge, let judge = judgeSelection ?? largestModel else { return }
        judgeSelection = judge
        isJudging = true
        judgeStatus = "Starting..."
        let cols = compareColumns.filter { $0.phase == .done && !$0.answer.isEmpty }
        for i in compareColumns.indices { compareColumns[i].score = nil }
        let answers = cols.map { (id: $0.id.uuidString, text: $0.answer) }
        let prompt = lastComparePrompt
        Task {
            do {
                for try await ev in api.judge(judge: judge, prompt: prompt, answers: answers) {
                    switch ev {
                    case .status(let s): judgeStatus = s
                    case .loaded: judgeStatus = "Judging..."; loadedModel = judge.model.name
                    case .score(let s):
                        if let i = compareColumns.firstIndex(where: { $0.id.uuidString == s.id }) {
                            compareColumns[i].score = s
                            let name = compareColumns[i].selection.shortLabel
                            if let ri = runs.lastIndex(where: { $0.source == "compare" && $0.model == name }) {
                                runs[ri].quality = s.overall
                            }
                        }
                    case .error(let e): presentError("Judging failed", e)
                    default: break
                    }
                }
            } catch {
                presentError("Judging failed", Self.describe(error))
            }
            saveRuns()
            judgeStatus = nil
            isJudging = false
        }
    }

    // MARK: Benchmarks

    static let needleLengthOptions = [1000, 2000, 4000, 8000, 16000, 32000, 64000]

    func runBenchmarks() {
        guard !isBenchmarking, !benchSelections.isEmpty, !benchSuites.isEmpty else { return }
        isBenchmarking = true
        let suites = Array(benchSuites).sorted()
        let lengths = Self.needleLengthOptions.filter { $0 <= benchMaxContext }
        let targets = benchSelections
        Task {
            for sel in targets {
                guard isBenchmarking else { break }
                var run = BenchmarkRun(model: sel.shortLabel, modelPath: sel.model.path)
                benchmarkRuns.insert(run, at: 0)
                let runId = run.id
                @MainActor func update(_ f: (inout BenchmarkRun) -> Void) {
                    if let i = benchmarkRuns.firstIndex(where: { $0.id == runId }) { f(&benchmarkRuns[i]) }
                }
                benchStatus = "\(sel.shortLabel): starting..."
                do {
                    for try await ev in api.evaluate(selection: sel, suites: suites, needleLengths: lengths, params: params) {
                        switch ev {
                        case .status(let s): benchStatus = "\(sel.shortLabel): \(s)"
                        case .loaded: loadedModel = sel.model.name
                        case .result(let r): update { $0.results.append(r) }
                        case .error(let e): update { $0.error = e }
                        default: break
                        }
                    }
                } catch {
                    update { $0.error = Self.describe(error) }
                }
                update { $0.finished = true }
                run = benchmarkRuns.first { $0.id == runId } ?? run
                saveBenchmarks()
            }
            benchStatus = nil
            isBenchmarking = false
        }
    }

    func stopBenchmarks() {
        isBenchmarking = false
        Task { await api.stop() }
    }

    func clearBenchmarks() {
        benchmarkRuns.removeAll()
        saveBenchmarks()
    }

    /// Latest finished benchmark per model, for the leaderboard.
    func latestBenchmark(for model: String) -> BenchmarkRun? {
        benchmarkRuns.first { $0.model == model && $0.finished && !$0.results.isEmpty }
    }

    // MARK: Export

    func exportChat(_ id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        var md = "# \(s.title)\n\n"
        for m in s.messages {
            if m.role == "user" {
                md += "## You\n\n"
                for a in m.attachments { md += "*Attached: \(a.name)*\n\n" }
                md += m.content + "\n\n"
            } else {
                md += "## \(m.modelLabel ?? "Assistant")\n\n" + splitReasoning(m.content).answer + "\n\n"
                if let st = m.stats {
                    md += String(format: "*%.1f tok/s · %d tokens · %.2fs*\n\n", st.tokensPerSecond, st.generationTokens, st.totalSeconds)
                }
            }
        }
        save(md, name: s.title)
    }

    func exportCompare() {
        var md = "# Model comparison\n\n**Prompt:** \(lastComparePrompt)\n\n"
        md += "| Model | tok/s | First token | Tokens | Memory | Quality |\n|---|---|---|---|---|---|\n"
        for c in compareColumns {
            let st = c.stats
            md += "| \(c.selection.shortLabel)\(c.isBest ? " ⭐" : "") | \(st.map { String(format: "%.1f", $0.tokensPerSecond) } ?? "-") | \(st.map { String(format: "%.2fs", $0.timeToFirstToken) } ?? "-") | \(st.map { "\($0.generationTokens)" } ?? "-") | \(st.map { String(format: "%.1f GB", $0.peakMemoryGb) } ?? "-") | \(c.score.map { String(format: "%.1f", $0.overall) } ?? "-") |\n"
        }
        for c in compareColumns {
            md += "\n## \(c.selection.shortLabel)\n\n\(c.answer)\n"
            if let s = c.score, !s.verdict.isEmpty { md += "\n> Judge: \(s.verdict)\n" }
        }
        save(md, name: "Model comparison")
    }

    private func save(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-").prefix(60) + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { presentError("Export failed", error.localizedDescription) }
        }
    }

    // MARK: Runs (leaderboard)

    private func recordRun(model: String, engine: String, source: String, stats: GenerationStats) {
        guard stats.generationTokens > 0 else { return }
        runs.append(RunRecord(model: model, engine: engine, source: source, stats: stats))
        if runs.count > 5000 { runs.removeFirst(runs.count - 5000) }
        saveRuns()
    }

    func clearRuns() {
        runs.removeAll()
        saveRuns()
    }

    // MARK: Persistence

    private var sessionsURL: URL { Self.dataDirectory.appendingPathComponent("chats.json") }
    private var runsURL: URL { Self.dataDirectory.appendingPathComponent("runs.json") }
    private var benchmarksURL: URL { Self.dataDirectory.appendingPathComponent("benchmarks.json") }

    func saveBenchmarks() {
        if let d = try? JSONEncoder().encode(benchmarkRuns) { try? d.write(to: benchmarksURL, options: .atomic) }
    }

    private func loadBenchmarks() {
        if let d = try? Data(contentsOf: benchmarksURL), let r = try? JSONDecoder().decode([BenchmarkRun].self, from: d) {
            benchmarkRuns = r.filter(\.finished)
        }
    }

    func saveSessions() {
        let clean = sessions.map { s -> ChatSession in
            var s = s
            s.messages = s.messages.map { var m = $0; m.isStreaming = false; m.status = nil; return m }
            return s
        }
        if let d = try? JSONEncoder().encode(clean) { try? d.write(to: sessionsURL, options: .atomic) }
    }

    private func loadSessions() {
        if let d = try? Data(contentsOf: sessionsURL), let s = try? JSONDecoder().decode([ChatSession].self, from: d) {
            sessions = s.sorted { $0.updated > $1.updated }
        }
    }

    func saveRuns() {
        if let d = try? JSONEncoder().encode(runs) { try? d.write(to: runsURL, options: .atomic) }
    }

    private func loadRuns() {
        if let d = try? Data(contentsOf: runsURL), let r = try? JSONDecoder().decode([RunRecord].self, from: d) { runs = r }
    }
}
