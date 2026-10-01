import AppKit
import SwiftUI

/// End-to-end self test, run with `ModelPlayground --selftest`.
/// Drives the real app state against the real backend, renders every screen to PNG
/// and exits with status 0 when all checks pass. Uses its own settings and data folder.
@MainActor
enum SelfTest {
    static var checks: [(String, Bool, String)] = []
    static var window: NSWindow?

    static var outDir: URL {
        let path = ProcessInfo.processInfo.environment["MP_SNAPSHOT_DIR"] ?? (NSTemporaryDirectory() + "mp-selftest")
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append((name, ok, detail))
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        fflush(stdout)
    }

    static func wait(_ seconds: Double, until cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return cond()
    }

    /// Focused test of one model, selected with MP_TEST_MODEL (a substring of its folder name).
    static func runModel(_ state: AppState, needle: String) async {
        try? FileManager.default.removeItem(at: AppState.dataDirectory.appendingPathComponent("chats.json"))
        try? FileManager.default.removeItem(at: AppState.dataDirectory.appendingPathComponent("runs.json"))
        try? FileManager.default.removeItem(at: AppState.dataDirectory.appendingPathComponent("benchmarks.json"))
        await state.boot()
        check("engine starts", state.serverState == .running)
        guard let target = state.selections.first(where: { $0.engine == "mlx" && $0.model.name.contains(needle) }) else {
            check("model \(needle) is installed", false, state.models.map(\.name).joined(separator: ", "))
            return finish()
        }
        check("model is installed", true, "\(target.model.name), \(target.model.sizeLabel), \(formatContext(target.model.context)) context")
        let rival = state.selections.first { $0.engine == "mlx" && $0.model.name.contains("Qwen3-4B-Instruct-2507") }

        func lastReply(_ id: UUID) -> ChatMessage? { state.sessions.first { $0.id == id }?.messages.last }
        func describe(_ m: ChatMessage?) -> String {
            guard let m else { return "none" }
            if let e = m.error { return "error: \(e)" }
            let st = m.stats.map { String(format: "%.1f tok/s, %d tokens, %.2fs first token, %.1f GB", $0.tokensPerSecond, $0.generationTokens, $0.timeToFirstToken, $0.peakMemoryGb) } ?? ""
            return "\(st) | \(splitReasoning(m.content).answer.prefix(120).replacingOccurrences(of: "\n", with: " "))"
        }

        // 1. Chat without thinking.
        state.params = GenParams(temperature: 0.3, maxTokens: 1024, thinking: false)
        let chat = state.newChat(with: target)
        state.send("In two sentences, what makes a good API design?", in: chat)
        _ = await wait(600) { state.generatingSession == nil }
        let r1 = lastReply(chat)
        check("chat (no thinking)", r1?.error == nil && !(r1?.content.isEmpty ?? true), describe(r1))

        // 2. Reasoning with thinking on.
        state.params.thinking = true
        state.params.maxTokens = 8000
        state.send("A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost? Give the final answer in cents.", in: chat)
        _ = await wait(1500) { state.generatingSession == nil }
        let r2 = lastReply(chat)
        let parts = splitReasoning(r2?.content ?? "")
        check("reasoning is folded into a thought block", (parts.reasoning?.count ?? 0) > 50 && !parts.thinking,
              "thought \(wordCount(parts.reasoning ?? "")) words")
        check("reasoning reaches a correct final answer", r2?.stats?.finishReason != "length" && parts.answer.contains("5")
              && !parts.answer.contains("10 cents"), describe(r2))

        // 3. Rich formatting.
        state.params.thinking = false
        state.send("Compare Python, Rust and Go for backend services in a markdown table (columns: speed, safety, learning curve), then give a 3-bullet recommendation.", in: chat)
        _ = await wait(600) { state.generatingSession == nil }
        let r3 = lastReply(chat)
        check("markdown table answer", (r3?.content.contains("|") ?? false), describe(r3))
        state.sidebarSelection = .chat(chat)
        await snapshot("m1-chat")

        // 4. Long document Q&A through an attachment (about 12K tokens).
        var doc = ""
        for i in 0..<220 {
            doc += "Section \(i + 1). The regional office filed its routine operations summary covering staffing, supplies and maintenance schedules for the quarter. "
            if i == 157 { doc += "Note for auditors: the backup generator at the Lisbon site was serviced on 14 March by technician Mara Okafor. " }
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ops-report.txt")
        try? doc.write(to: file, atomically: true, encoding: .utf8)
        state.params.kvBits = 8
        let docChat = state.newChat(with: target)
        state.addAttachments([file], to: docChat)
        state.send("Who serviced the backup generator at the Lisbon site, and on what date?", in: docChat)
        _ = await wait(900) { state.generatingSession == nil }
        let r4 = lastReply(docChat)
        let a4 = r4?.content.lowercased() ?? ""
        check("long document Q&A (8-bit KV cache)", a4.contains("okafor") && a4.contains("14"),
              "prompt \(r4?.stats?.promptTokens ?? 0) tokens · " + describe(r4))
        state.params.kvBits = 0
        state.sidebarSelection = .chat(docChat)
        await snapshot("m2-document")

        // 5. Benchmarks up to 32K tokens (MP_SKIP_BENCH=1 skips this slow part).
        if ProcessInfo.processInfo.environment["MP_SKIP_BENCH"] == nil {
        state.benchSelections = [target] + (rival.map { [$0] } ?? [])
        state.benchSuites = ["quick", "needle"]
        state.benchMaxContext = 32000
        state.sidebarSelection = .benchmarks
        state.runBenchmarks()
        _ = await wait(3600) { !state.isBenchmarking }
        for run in state.benchmarkRuns.prefix(state.benchSelections.count) {
            let fails = run.quiz.filter { !$0.passed }.map { "\($0.id)=\($0.output.prefix(25))" }.joined(separator: "; ")
            check("benchmark \(run.model)", run.finished && run.error == nil,
                  "quiz \(run.quiz.filter(\.passed).count)/\(run.quiz.count), context \(run.needle.filter(\.passed).count)/\(run.needle.count), reliable to \(run.maxReliableContext.map(formatContext) ?? "-"), max prompt speed at 32K \(Int(run.needle.filter { $0.contextTokens > 25000 }.map(\.promptTokensPerSecond).max() ?? 0)) tok/s, peak \(String(format: "%.1f", run.needle.map(\.peakMemoryGb).max() ?? 0)) GB" + (fails.isEmpty ? "" : " · missed: \(fails)"))
        }
        await snapshot("m3-benchmarks")
        }

        // 6. Head-to-head with a judge.
        if let rival {
            state.compareColumns = []
            state.addCompare(target)
            state.addCompare(rival)
            state.params = GenParams(temperature: 0.3, maxTokens: 800, thinking: false)
            state.comparePrompt = "Explain to a new engineer why database indexes speed up reads but slow down writes. Keep it under 120 words."
            state.sidebarSelection = .compare
            state.runCompare()
            _ = await wait(900) { !state.isComparing }
            state.judgeSelection = target
            state.runJudge()
            _ = await wait(900) { !state.isJudging }
            for c in state.compareColumns {
                check("compare \(c.selection.shortLabel) is answered and judged", c.error == nil && c.stats != nil && (c.score?.overall ?? 0) > 0,
                      String(format: "%.1f tok/s, %d tokens, judge %.1f/10 · %@", c.stats?.tokensPerSecond ?? 0, c.stats?.generationTokens ?? 0, c.score?.overall ?? 0, c.score?.verdict ?? ""))
            }
            state.compareTab = .answers
            await snapshot("m4-compare")
            state.compareTab = .quality
            await snapshot("m5-quality")
        }
        finish()
    }

    static func run(_ state: AppState) async {
        // Start from a clean slate inside the self-test data folder.
        try? FileManager.default.removeItem(at: AppState.dataDirectory.appendingPathComponent("chats.json"))
        try? FileManager.default.removeItem(at: AppState.dataDirectory.appendingPathComponent("runs.json"))
        state.params = GenParams(temperature: 0, maxTokens: 400, thinking: false)

        await state.boot()
        check("engine starts on a free port", state.serverState == .running, "port \(state.port)")
        guard state.serverState == .running else { return finish() }
        check("catalog loads", state.catalog.count >= 60, "\(state.catalog.count) models")
        check("installed models are found", state.models.count >= 2, state.models.map(\.name).joined(separator: ", "))

        func pick(_ needle: String) -> ModelSelection? {
            state.selections.first { $0.engine == "mlx" && $0.model.name.contains(needle) }
        }
        guard let qwen = pick("Qwen3-0.6B"), let lfm = pick("LFM2.5-1.2B") else {
            check("test models present", false, "need Qwen3-0.6B and LFM2.5-1.2B in the models folder")
            return finish()
        }
        let judge = pick("Qwen3-4B-Instruct-2507") ?? state.largestModel

        state.sidebarSelection = .models
        await snapshot("01-library")

        // Welcome screen.
        let chat = state.newChat(with: qwen)
        await snapshot("02-welcome")

        // Chat round trip.
        state.send("What is 12 * 12? Answer in one short sentence.", in: chat)
        _ = await wait(180) { state.generatingSession == nil }
        var reply = state.sessions.first { $0.id == chat }?.messages.last
        check("chat reply streams", reply?.content.contains("144") == true, String((reply?.content ?? reply?.error ?? "none").suffix(100)))
        check("chat reply has stats", (reply?.stats?.tokensPerSecond ?? 0) > 0,
              reply?.stats.map { String(format: "%.0f tok/s, %d tokens", $0.tokensPerSecond, $0.generationTokens) } ?? "none")

        // Follow-up with an attached file (long-context style).
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("mp-notes.txt")
        try? "Project notes.\nThe secret codeword for the launch is PERIWINKLE.\nShip date: Friday.".write(to: file, atomically: true, encoding: .utf8)
        state.addAttachments([file], to: chat)
        check("attachment is added", state.pendingAttachments[chat]?.count == 1)
        state.send("What is the secret codeword in the attached file? Reply with just the word.", in: chat)
        _ = await wait(180) { state.generatingSession == nil }
        reply = state.sessions.first { $0.id == chat }?.messages.last
        check("model reads the attached file", reply?.content.uppercased().contains("PERIWINKLE") == true,
              String((reply?.content ?? reply?.error ?? "none").suffix(100)))

        // Rich Markdown rendering.
        state.send("Give a markdown answer: a heading, a 3-item bullet list, a small table comparing cats and dogs, and a Python code block printing hello.", in: chat)
        _ = await wait(180) { state.generatingSession == nil }
        state.sidebarSelection = .chat(chat)
        await snapshot("03-chat")
        await snapshot("04-chat-dark", dark: true)

        // Regenerate.
        let before = state.sessions.first { $0.id == chat }?.messages.count ?? 0
        state.regenerate(in: chat)
        _ = await wait(180) { state.generatingSession == nil }
        let after = state.sessions.first { $0.id == chat }?.messages.count ?? 0
        check("regenerate replaces the last reply", before == after && state.sessions.first { $0.id == chat }?.messages.last?.content.isEmpty == false)

        // Stop mid-generation.
        state.send("Write a 600-word story about a lighthouse keeper.", in: chat)
        _ = await wait(60) { (state.sessions.first { $0.id == chat }?.messages.last?.content.count ?? 0) > 40 }
        state.stopGenerating()
        _ = await wait(30) { state.generatingSession == nil }
        reply = state.sessions.first { $0.id == chat }?.messages.last
        check("stop ends generation early", reply?.stats?.finishReason == "cancelled", reply?.stats?.finishReason ?? "none")

        // Compare.
        state.compareColumns = []
        state.addCompare(qwen)
        state.addCompare(lfm)
        if let judge, judge.id != qwen.id { state.addCompare(judge) }
        state.comparePrompt = "Name three primary colors and explain in one sentence why they are called primary."
        state.sidebarSelection = .compare
        state.runCompare()
        _ = await wait(400) { !state.isComparing }
        let cols = state.compareColumns
        check("compare runs every model", cols.allSatisfy { $0.phase == .done && !$0.answer.isEmpty },
              cols.map { "\($0.selection.shortLabel): \($0.answer.count) chars \($0.error ?? "")" }.joined(separator: "; "))
        check("compare collects stats", cols.allSatisfy { ($0.stats?.tokensPerSecond ?? 0) > 0 })
        check("tokenizer comparison counts prompt tokens", cols.allSatisfy { ($0.promptTokenCount ?? 0) > 0 },
              cols.map { "\($0.selection.shortLabel)=\($0.promptTokenCount ?? -1)" }.joined(separator: ", "))
        state.compareTab = .answers
        await snapshot("05-compare-answers")
        state.compareTab = .stats
        await snapshot("06-compare-stats")

        // Judge.
        state.judgeSelection = judge
        state.runJudge()
        _ = await wait(600) { !state.isJudging }
        let scored = state.compareColumns.compactMap(\.score)
        check("judge scores every answer", scored.count == cols.count, scored.map { String(format: "%.1f", $0.overall) }.joined(separator: ", "))
        check("judge scores are in range", !scored.isEmpty && scored.allSatisfy { $0.overall > 0 && $0.overall <= 10 })
        if let first = state.compareColumns.first { state.markBest(first.id) }
        check("vote is recorded", state.runs.contains { $0.wonVote })
        state.compareTab = .quality
        await snapshot("07-compare-quality")

        // Blind arena.
        state.compareBlind = true
        state.comparePrompt = "Say hello in French. One word."
        state.runCompare()
        _ = await wait(300) { !state.isComparing }
        let hidden = state.compareColumns.map { state.displayName($0) }
        check("blind mode hides model names", hidden.allSatisfy { $0.hasPrefix("Model ") }, hidden.joined(separator: ", "))
        state.compareTab = .answers
        await snapshot("07b-compare-blind")
        if let first = state.compareColumns.first { state.markBest(first.id) }
        check("voting reveals names", !state.displayName(state.compareColumns[0]).hasPrefix("Model "))
        state.compareBlind = false

        // Benchmarks: quiz plus long-context retrieval.
        state.benchSelections = [qwen, lfm]
        state.benchSuites = ["quick", "needle"]
        state.benchMaxContext = 4000
        state.sidebarSelection = .benchmarks
        state.runBenchmarks()
        _ = await wait(900) { !state.isBenchmarking }
        let runs = state.benchmarkRuns.prefix(2)
        check("benchmarks run for each model", runs.count == 2 && runs.allSatisfy { $0.finished && $0.error == nil },
              runs.map { "\($0.model) err=\($0.error ?? "none")" }.joined(separator: "; "))
        check("quiz is graded", runs.allSatisfy { $0.quiz.count == 13 },
              runs.map { "\($0.model) \($0.quiz.filter(\.passed).count)/\($0.quiz.count)" }.joined(separator: ", "))
        check("context test covers lengths and depths", runs.allSatisfy { $0.needle.count == 9 },
              runs.map { "\($0.model) \($0.needle.filter(\.passed).count)/\($0.needle.count), reliable to \($0.maxReliableContext.map(formatContext) ?? "-")" }.joined(separator: ", "))
        await snapshot("08a-benchmarks")

        // Leaderboard and settings.
        check("runs recorded for leaderboard", state.runs.count >= 5, "\(state.runs.count) runs")
        check("judged quality reaches leaderboard", state.runs.contains { $0.quality != nil })
        state.sidebarSelection = .leaderboard
        await snapshot("08-leaderboard")
        state.sidebarSelection = .settings
        await snapshot("09-settings")

        // Persistence.
        state.saveSessions()
        let data = try? Data(contentsOf: AppState.dataDirectory.appendingPathComponent("chats.json"))
        let decoded = data.flatMap { try? JSONDecoder().decode([ChatSession].self, from: $0) }
        check("chats persist to disk", decoded?.first { $0.id == chat }?.messages.count == state.sessions.first { $0.id == chat }?.messages.count)

        finish()
    }

    static func finish() {
        let failed = checks.filter { !$0.1 }
        print("\n\(checks.count - failed.count)/\(checks.count) checks passed. Snapshots: \(outDir.path)")
        fflush(stdout)
        AppState.shared.stopServer()
        exit(failed.isEmpty && !checks.isEmpty ? 0 : 1)
    }

    /// Renders the whole window (including toolbar) into a PNG without needing screen recording.
    static func snapshot(_ name: String, dark: Bool = false) async {
        let size = NSSize(width: 1320, height: 840)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .miniaturizable],
                             backing: .buffered, defer: false)
            w.toolbarStyle = .unified
            w.titleVisibility = .hidden
            w.contentView = NSHostingView(rootView: ContentView().environment(AppState.shared))
            w.setFrame(NSRect(origin: NSPoint(x: 40, y: 40), size: size), display: true)
            // A hidden or transparent window counts as occluded, and SwiftUI then skips lazy content,
            // so the test window is briefly shown while snapshots are taken.
            w.level = .floating
            w.orderFrontRegardless()
            window = w
        }
        guard let w = window else { return }
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try? await Task.sleep(for: .milliseconds(1800))
        let url = outDir.appendingPathComponent("\(name).png")
        // Capture through the window server so scroll views and materials render exactly as on screen.
        // An app may capture its own windows without screen-recording permission.
        typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") {
            let capture = unsafeBitCast(sym, to: CaptureFn.self)
            // .optionIncludingWindow, .boundsIgnoreFraming | .bestResolution
            if let image = capture(.null, 1 << 3, UInt32(w.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        guard let frameView = w.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
