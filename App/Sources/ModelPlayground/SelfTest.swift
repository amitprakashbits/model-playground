import AppKit
import SwiftUI
import WebKit

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
        let env = ProcessInfo.processInfo.environment
        let rivalName = env["MP_RIVAL"] ?? "Qwen3-4B-Instruct-2507"
        let rival = state.selections.first { $0.engine == "mlx" && $0.model.name.contains(rivalName) && $0.id != target.id }

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
        // The first amount the answer states must be 5 cents. Worked steps often mention 110 cents
        // or discuss the intuitive-but-wrong 10 cents, so only the leading claim is checked.
        var stated: Int?
        if let m = parts.answer.lowercased().firstMatch(of: /(\d+)\s*(?:cents|¢)|\$0?\.(\d\d)\b/) {
            if let c = m.output.1 { stated = Int(c) } else if let d = m.output.2 { stated = Int(d) }
        }
        check("reasoning reaches a correct final answer", r2?.stats?.finishReason != "length" && stated == 5, describe(r2))

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
        state.benchMaxContext = Int(env["MP_BENCH_MAX"] ?? "") ?? 32000
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

    /// Measures how responsive the main thread (typing, scrolling) stays while a reply streams
    /// into a long chat. Run with MP_PERF=1.
    static func runPerf(_ state: AppState) async {
        try? FileManager.default.removeItem(at: AppState.dataDirectory.appendingPathComponent("chats.json"))
        await state.boot()
        guard state.serverState == .running,
              let model = state.selections.first(where: { $0.engine == "mlx" && $0.model.name.contains("Qwen3-0.6B") }) else {
            check("perf setup", false, "needs Qwen3-0.6B"); return finish()
        }
        // A long chat like a real working session: 10 rich Markdown replies.
        let sample = (1...6).map { i in
            "## Section \(i)\n\nHere is a **detailed** answer with `inline code`, a [link](https://example.com) and a list:\n\n- First point about SEO and *structure*\n- Second point with more detail and context\n  continuing on the next line\n- Third point\n\n| Metric | Value |\n|---|---|\n| Speed | Fast |\n| Size | 12 KB |\n\n```swift\nlet x = \(i)\nprint(x)\n```\n\n> A short quote for flavour.\n"
        }.joined(separator: "\n")
        let chat = state.newChat(with: model)
        if let i = state.index(of: chat) {
            for n in 0..<10 {
                state.sessions[i].messages.append(ChatMessage(role: "user", content: "Question \(n): explain step \(n) in detail."))
                state.sessions[i].messages.append(ChatMessage(role: "assistant", content: sample, modelLabel: model.shortLabel))
            }
        }
        state.sidebarSelection = .chat(chat)
        await snapshot("perf-chat")  // also opens the window so the chat is really rendered
        state.params = GenParams(temperature: 0.7, maxTokens: 500, thinking: false)

        // Sample main-thread lateness every 10 ms while the reply streams.
        var lags: [Double] = []
        var stallLog: [String] = []
        let start = CFAbsoluteTimeGetCurrent()
        var last = start
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            let lag = max(0, (now - last) - 0.01) * 1000
            lags.append(lag)
            if lag > 50 { stallLog.append(String(format: "%.0fms at %.1fs", lag, now - start)) }
            last = now
        }
        RunLoop.main.add(timer, forMode: .common)
        state.send("Write a long, well-structured markdown guide to technical SEO with headings, lists and a table.", in: chat)
        _ = await wait(300) { state.generatingSession == nil }
        timer.invalidate()
        let reply = state.sessions.first { $0.id == chat }?.messages.last
        let sorted = lags.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let stalls = lags.filter { $0 > 50 }.count
        let busy = lags.reduce(0, +) / 1000
        let secs = Double(lags.count) * 0.01 + busy
        let summary = String(format: "p50 %.1f ms, p95 %.1f ms, max %.0f ms, %d stalls over 50 ms, main thread blocked %.0f%% of %.1fs, %d tokens",
                             pct(0.5), pct(0.95), sorted.last ?? 0, stalls, secs > 0 ? busy / secs * 100 : 0, secs, reply?.stats?.generationTokens ?? 0)
        print("PERF " + summary)
        print("STALLS " + stallLog.joined(separator: ", "))
        check("main thread stays responsive while streaming", pct(0.95) < 25 && stalls < 5, summary)
        finish()
    }

    /// Generates real artboards with the design model (MP_STUDIO=1) to judge design quality.
    static func runStudio(_ state: AppState) async {
        await state.boot()
        guard state.serverState == .running else { return finish() }
        state.studio = DesignSystem(brand: "Orbit", brief: "A habit tracker that helps remote teams build healthy routines together.",
                                    style: "Minimal", primaryHex: "#0EA5E9", font: "Inter", radius: 16)
        state.studioArtboards = (ProcessInfo.processInfo.environment["MP_STUDIO"] ?? "landing,pricing")
            .split(separator: ",").map(String.init)
        if let name = ProcessInfo.processInfo.environment["MP_STUDIO_MODEL"] {
            state.studioSelection = state.selections.first { $0.engine == "mlx" && $0.model.name.contains(name) }
        }
        state.sidebarSelection = .studio
        state.runStudio()
        let ids = state.studioArtboards
        _ = await wait(3600) { !state.isDesigning && ids.allSatisfy { state.studioResults[$0]?.phase == .done } }
        for id in ids {
            let r = state.studioResults[id]
            check("artboard \(id)", r?.html != nil && r?.error == nil,
                  "\((state.studioSelection ?? state.designModel)?.shortLabel ?? "?"): \(r?.html?.count ?? 0) chars, \(r?.stats?.generationTokens ?? 0) tokens, \(String(format: "%.0f", r?.stats?.totalSeconds ?? 0))s, finish=\(r?.stats?.finishReason ?? "-") \(r?.error ?? "") file=\(r?.savedPath ?? "")")
        }
        try? await Task.sleep(for: .seconds(5))
        await snapshot("studio-run")
        finish()
    }

    /// Opens the user's real data, visits every screen and reports how long each one blocks the
    /// main thread. Sends nothing and saves nothing. Run with MP_DIAG=1.
    static func runDiagnosis(_ state: AppState) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        await state.boot()
        print(String(format: "DIAG boot %.1fs, engine=%@, models=%d, chats=%d, runs=%d, agents=%d", CFAbsoluteTimeGetCurrent() - t0,
                     "\(state.serverState)", state.models.count, state.sessions.count, state.runs.count, state.agents.count))
        var screens: [(String, SidebarItem)] = [("library", .models), ("compare", .compare), ("agents", .agents),
                                                ("benchmarks", .benchmarks), ("leaderboard", .leaderboard), ("settings", .settings)]
        for (i, s) in state.sessions.prefix(4).enumerated() { screens.insert(("chat\(i + 1)", .chat(s.id)), at: i) }
        state.sidebarSelection = .settings
        await snapshot("diag-warmup")  // creates the window; not counted
        for (name, item) in screens {
            var worst = 0.0
            var last = CFAbsoluteTimeGetCurrent()
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                let now = CFAbsoluteTimeGetCurrent(); worst = max(worst, (now - last - 0.01) * 1000); last = now
            }
            RunLoop.main.add(timer, forMode: .common)
            state.sidebarSelection = item
            try? await Task.sleep(for: .seconds(1.5))
            timer.invalidate()
            print(String(format: "DIAG %-11@ worst freeze %.0f ms", name as NSString, worst))
            await snapshot("diag-\(name)")
        }
        exit(0)  // skip applicationWillTerminate so nothing is saved
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

        // Design: the UI designer preset produces a page that opens in the canvas.
        let designer = judge ?? qwen
        let designChat = state.newChat(with: designer)
        let savedParams = state.params
        state.params.systemPrompt = PromptPreset.all.first { $0.name == "UI designer" }!.prompt
        state.params.maxTokens = 1800
        state.params.thinking = false
        state.sidebarSelection = .chat(designChat)
        state.send("Design a pricing card for a 'Pro' plan at $12/month with 4 features and a call-to-action button.", in: designChat)
        _ = await wait(900) { state.generatingSession == nil }
        let design = state.sessions.first { $0.id == designChat }?.messages.last
        let html = design.flatMap { extractHTML($0.content) }
        check("designer reply contains a page", html != nil, "\(html?.count ?? 0) characters of HTML")
        check("canvas opens automatically", state.canvasHTML != nil && state.canvasHTML == html)
        _ = await wait(20) { HTMLPreview.lastLoadFinished }
        try? await Task.sleep(for: .seconds(2))  // let Tailwind (CDN) style the page
        let rendered = await renderedPreviewStats()
        check("canvas renders the page", rendered.distinctColors > 8, "\(rendered.distinctColors) distinct colors in the preview")
        await snapshot("03c-design-canvas")
        state.canvasHTML = nil
        state.params = savedParams

        // Edit and resend: the message returns to the composer and later turns are removed.
        if let userMsg = state.sessions.first(where: { $0.id == designChat })?.messages.first {
            state.editMessage(userMsg.id, in: designChat)
            check("edit puts the message back in the composer", (state.drafts[designChat] ?? "").contains("pricing card")
                  && state.sessions.first { $0.id == designChat }?.messages.isEmpty == true)
            state.drafts[designChat] = nil
        }

        // Folder attachment and saved prompts.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mp-folder-test")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try? "print('hello')".write(to: folder.appendingPathComponent("src/app.py"), atomically: true, encoding: .utf8)
        try? "# Readme".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try? "ignored".write(to: folder.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)
        state.attachFolder(folder, to: designChat)
        let names = (state.pendingAttachments[designChat] ?? []).map(\.name).sorted()
        check("folder attach reads code and skips dependencies", names == ["README.md", "src/app.py"], names.joined(separator: ", "))
        state.pendingAttachments[designChat] = nil
        state.savedPrompts.removeAll { $0 == "selftest prompt" }
        state.savedPrompts.insert("selftest prompt", at: 0)
        check("saved prompts persist", (UserDefaults(suiteName: "local.modelplayground.selftest")?.stringArray(forKey: "savedPrompts") ?? []).contains("selftest prompt"))
        state.savedPrompts.removeAll { $0 == "selftest prompt" }

        // AirLLM chat through the engine switch.
        if let air = state.selections.first(where: { $0.engine == "airllm" && $0.model.name.contains("Llama-3.2-1B") })
            ?? state.selections.first(where: { $0.engine == "airllm" }) {
            let airChat = state.newChat(with: ModelSelection(model: air.model, engine: "mlx"))
            state.setSelection(air, for: airChat)  // what the MLX/AirLLM switch does
            let saved = state.params
            state.params.maxTokens = 12
            state.params.temperature = 0
            state.send("What is the capital of Japan? One short sentence.", in: airChat)
            _ = await wait(900) { state.generatingSession == nil }
            let r = state.sessions.first { $0.id == airChat }?.messages.last
            check("chat runs on AirLLM", r?.stats?.engine == "airllm" && (r?.content.lowercased().contains("tokyo") ?? false),
                  "\(air.model.name): \(r?.content.prefix(60) ?? "") \(r?.error ?? "") · \(String(format: "%.2f tok/s, %.1f GB", r?.stats?.tokensPerSecond ?? 0, r?.stats?.peakMemoryGb ?? 0))")
            state.sidebarSelection = .chat(airChat)
            await snapshot("03b-chat-airllm")
            state.params = saved
        } else {
            check("chat runs on AirLLM", false, "no AirLLM-capable model installed")
        }

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
        state.compareTab = .preview
        await snapshot("06b-compare-preview")

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

        // Agents: a team in independent mode with a synthesizer, then chain mode.
        state.params.maxTokens = 300
        state.params.thinking = false
        if let panel = AgentTeamPreset.all.first(where: { $0.name == "Brainstorm" }) { state.applyTeam(panel) }
        check("team preset loads agents", state.agents.count == 4, state.agents.map(\.name).joined(separator: ", "))
        state.agents[0].selection = qwen; state.agents[1].selection = lfm
        state.agents[2].selection = qwen; state.agents[3].selection = lfm
        state.agentMode = .independent
        state.agentSynthesize = true
        state.synthSelection = judge ?? qwen
        state.agentPrompt = "Suggest one name for a coffee shop run by robots. Reply with the name and one sentence."
        state.sidebarSelection = .agents
        state.runAgents()
        _ = await wait(600) { !state.isRunningAgents }
        let outs = state.agents.map { state.agentOutputs[$0.id] ?? AgentOutput() }
        check("every agent answers in the grid", outs.allSatisfy { $0.phase == .done && !$0.answer.isEmpty && $0.error == nil },
              outs.map { "\($0.answer.prefix(30))" }.joined(separator: " | "))
        check("agents record stats", outs.allSatisfy { ($0.stats?.tokensPerSecond ?? 0) > 0 })
        check("synthesizer merges the answers", !state.synthOutput.answer.isEmpty && state.synthOutput.error == nil,
              String(state.synthOutput.answer.prefix(80)))
        check("progress reaches the end", state.agentProgress.done == state.agentProgress.total, "\(state.agentProgress.done)/\(state.agentProgress.total)")
        await snapshot("07c-agents")

        if let debate = AgentTeamPreset.all.first(where: { $0.name == "Debate" }) { state.applyTeam(debate) }
        for i in state.agents.indices { state.agents[i].selection = judge ?? qwen }
        state.agentPrompt = "Proposition: remote work is better than office work. Keep it to 3 sentences."
        state.runAgents()
        _ = await wait(600) { !state.isRunningAgents }
        let chain = state.agents.map { state.agentOutputs[$0.id]?.answer ?? "" }
        check("chain mode runs every agent in order", state.agentMode == .chain && chain.allSatisfy { !$0.isEmpty },
              chain.map { String($0.prefix(25)) }.joined(separator: " | "))
        await snapshot("07d-agents-debate")
        state.params.maxTokens = 400

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

        // Design studio (slow: one full page with the design model). Opt in with MP_DESIGN=1.
        if ProcessInfo.processInfo.environment["MP_DESIGN"] != nil {
        state.studio = DesignSystem(brand: "Orbit", brief: "A habit tracker that helps remote teams build healthy routines.",
                                    style: "Minimal", primaryHex: "#0EA5E9", font: "Inter", radius: 16)
        state.studioArtboards = ["components"]
        state.studioSelection = state.designModel
        state.sidebarSelection = .studio
        state.runStudio()
        _ = await wait(900) { !state.isDesigning && state.studioResults["components"]?.phase == .done }
        let board = state.studioResults["components"]
        check("studio generates an artboard", board?.html != nil,
              "\(state.studioSelection?.shortLabel ?? "?"): \(board?.html?.count ?? 0) chars \(board?.error ?? "")")
        check("studio injects the shared design system", board?.html?.contains("--brand:#0EA5E9") == true)
        check("studio saves the page to disk", board?.savedPath.map { FileManager.default.fileExists(atPath: $0) } == true,
              board?.savedPath ?? "not saved")
        try? await Task.sleep(for: .seconds(4))
        await snapshot("07e-studio")
        }

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

    /// Snapshots the live preview web view and counts distinct colors (a blank page has one or two).
    static func renderedPreviewStats() async -> (distinctColors: Int, Void) {
        guard let view = HTMLPreview.lastView else { return (0, ()) }
        let image: NSImage? = await withCheckedContinuation { cont in
            view.takeSnapshot(with: nil) { img, _ in cont.resume(returning: img) }
        }
        guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return (0, ()) }
        try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent("03d-canvas-webview.png"))
        var colors = Set<UInt32>()
        let stepX = max(1, rep.pixelsWide / 80), stepY = max(1, rep.pixelsHigh / 80)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        }
        return (colors.count, ())
    }

    /// Web content is drawn in a separate process and is missing from window captures, so each
    /// visible web view is snapshotted through WebKit and drawn into the screenshot.
    static func compositeWebViews(onto image: CGImage, window: NSWindow) async -> CGImage {
        guard let root = window.contentView else { return image }
        var webViews: [WKWebView] = []
        func collect(_ v: NSView) {
            if let wv = v as? WKWebView, !wv.isHiddenOrHasHiddenAncestor, wv.bounds.width > 10 { webViews.append(wv) }
            v.subviews.forEach(collect)
        }
        collect(root)
        guard !webViews.isEmpty else { return image }
        let scale = CGFloat(image.width) / window.frame.width
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for wv in webViews {
            let snap: NSImage? = await withCheckedContinuation { cont in wv.takeSnapshot(with: nil) { img, _ in cont.resume(returning: img) } }
            guard let cg = snap?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            // Window frame coordinates have their origin at the bottom left, like the bitmap context.
            let r = wv.convert(wv.bounds, to: nil)
            let titlebar = window.frame.height - (window.contentView?.frame.height ?? window.frame.height)
            _ = titlebar
            ctx.saveGState()
            ctx.clip(to: CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale))
            ctx.draw(cg, in: CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale))
            ctx.restoreGState()
        }
        return ctx.makeImage() ?? image
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
                let composed = await compositeWebViews(onto: image, window: w)
                try? NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        guard let frameView = w.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
