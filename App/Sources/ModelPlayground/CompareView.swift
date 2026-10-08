import Charts
import SwiftUI

struct CompareView: View {
    @Environment(AppState.self) private var state
    @State private var showInspector = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if state.compareColumns.isEmpty {
                    EmptyState(icon: "rectangle.split.3x1", title: "Compare models side by side",
                               message: "Add up to 4 models, then send one prompt. They run one after another, since only one model fits in memory at a time. Afterwards you get speed, token and quality comparisons.")
                } else {
                    switch state.compareTab {
                    case .answers: AnswersGrid()
                    case .preview: PreviewGrid()
                    case .stats: CompareStats()
                    case .quality: CompareQuality()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer
        }
        .background(Theme.background)
        .navigationTitle("Compare")
        .onAppear(perform: state.prefillCompare)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Bindable(state).compareBlind) { Label("Blind mode", systemImage: state.compareBlind ? "eye.slash" : "eye") }
                    .help("Blind arena: hide and shuffle model names until you vote")
                Button { state.exportCompare() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export comparison report as Markdown")
                    .disabled(state.compareColumns.allSatisfy { $0.stats == nil })
                Button { showInspector.toggle() } label: { Label("Generation Settings", systemImage: "slider.horizontal.3") }
            }
        }
        .inspector(isPresented: $showInspector) {
            ParamsForm().inspectorColumnWidth(min: 270, ideal: 300, max: 380)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(Array(state.compareColumns.enumerated()), id: \.element.id) { i, col in
                HStack(spacing: 6) {
                    Circle().fill(Theme.seriesColor(i)).frame(width: 8, height: 8)
                    Text(state.compareBlind && !state.compareRevealed && state.compareColumns.contains { $0.phase != .idle }
                         ? state.displayName(col) : col.selection.shortLabel)
                        .font(.callout.weight(.medium)).lineLimit(1)
                    if !state.isComparing {
                        Button { state.removeCompare(col.id) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.border))
            }
            if state.compareColumns.count < 4 && !state.isComparing {
                ModelPicker(selection: nil, placeholder: state.compareColumns.isEmpty ? "Add a model" : "Add") { state.addCompare($0) }
            }
            Spacer()
            Picker("", selection: Bindable(state).compareTab) {
                ForEach(CompareTab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var composer: some View {
        @Bindable var state = state
        return VStack(spacing: 6) {
            if state.compareColumns.isEmpty && !state.comparePrompt.isEmpty {
                Label("Add at least one model above to send this prompt.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !state.lastComparePrompt.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble").foregroundStyle(Theme.secondaryText)
                    Text(state.lastComparePrompt).lineLimit(1).foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .font(.caption)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(state.compareColumns.isEmpty ? "Add a model above first, then type a prompt..." : "One prompt, sent to every model...",
                          text: $state.comparePrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(state.runCompare)
                if state.isComparing || state.isJudging {
                    Button(action: state.stopCompare) {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(Theme.text, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                } else {
                    let ok = !state.compareColumns.isEmpty && !state.comparePrompt.trimmingCharacters(in: .whitespaces).isEmpty
                    Button(action: state.runCompare) {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(ok ? Theme.accent : Theme.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                }
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Answers

struct AnswersGrid: View {
    @Environment(AppState.self) private var state

    private var fastestId: UUID? {
        let done = state.compareColumns.filter { ($0.stats?.tokensPerSecond ?? 0) > 0 }
        guard done.count > 1 else { return nil }
        return done.max { ($0.stats?.tokensPerSecond ?? 0) < ($1.stats?.tokensPerSecond ?? 0) }?.id
    }

    private var topScoreId: UUID? {
        let scored = state.compareColumns.filter { ($0.score?.overall ?? 0) > 0 }
        guard scored.count > 1 else { return nil }
        return scored.max { ($0.score?.overall ?? 0) < ($1.score?.overall ?? 0) }?.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(state.compareColumns.enumerated()), id: \.element.id) { i, col in
                CompareColumnView(column: col, color: Theme.seriesColor(i), fastest: fastestId == col.id,
                                  topScore: topScoreId == col.id)
            }
        }
        .padding(16)
    }
}

struct CompareColumnView: View {
    @Environment(AppState.self) private var state
    var column: CompareColumn
    var color: Color
    var fastest: Bool
    var topScore: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(state.displayName(column)).font(.headline).lineLimit(1)
                Spacer()
                if column.phase == .done && column.error == nil {
                    Button { state.markBest(column.id) } label: {
                        Image(systemName: column.isBest ? "star.fill" : "star")
                            .foregroundStyle(column.isBest ? .yellow : Theme.secondaryText)
                    }
                    .buttonStyle(.borderless)
                    .help("Vote: best answer")
                    Button { copyToPasteboard(column.answer) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.secondaryText)
                        .help("Copy answer")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            HStack(spacing: 4) {
                if state.compareBlind && !state.compareRevealed {
                    Badge(text: "Hidden until you vote", systemImage: "eye.slash")
                } else {
                    EngineBadge(engine: column.selection.engine)
                    Badge(text: column.selection.model.sizeLabel)
                }
                if fastest { Badge(text: "Fastest", color: .green, systemImage: "hare.fill") }
                if topScore { Badge(text: "Top score", color: Theme.accent, systemImage: "rosette") }
                if column.isBest { Badge(text: "Your pick", color: .yellow, systemImage: "star.fill") }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let status = column.status {
                        HStack(spacing: 8) {
                            if column.phase == .running { SparkleSpinner() }
                            else { Image(systemName: "hourglass").foregroundStyle(Theme.secondaryText) }
                            Text(status).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if !column.output.isEmpty {
                        MessageContent(text: column.output, isStreaming: column.phase == .running, font: .system(size: 14))
                    }
                    if let e = column.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if column.phase == .idle && column.output.isEmpty && column.error == nil {
                        Text("Ready").foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let s = column.stats {
                Divider()
                HStack(spacing: 0) {
                    metric("Speed", String(format: "%.0f t/s", s.tokensPerSecond))
                    metric("First token", String(format: "%.2fs", s.timeToFirstToken))
                    metric("Tokens", "\(s.generationTokens)")
                    if let sc = column.score { metric("Quality", String(format: "%.1f", sc.overall)) }
                    else { metric("Memory", String(format: "%.1f GB", s.peakMemoryGb)) }
                }
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(column.phase == .running ? color.opacity(0.8) : (column.isBest ? Color.yellow.opacity(0.8) : Theme.border),
                        lineWidth: column.phase == .running || column.isBest ? 2 : 1)
        )
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

/// Renders each model's generated page side by side, for judging designs.
struct PreviewGrid: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(state.compareColumns.enumerated()), id: \.element.id) { i, col in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.seriesColor(i)).frame(width: 9, height: 9)
                        Text(state.displayName(col)).font(.headline).lineLimit(1)
                        Spacer()
                        if col.isBest { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                        if let html = extractHTML(col.output) {
                            Button { state.canvasHTML = html; if let id = state.sessions.first?.id { state.sidebarSelection = .chat(id) } } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.borderless)
                            .help("Open large in the canvas")
                        }
                        if col.phase == .done {
                            Button { state.markBest(col.id) } label: {
                                Image(systemName: col.isBest ? "star.fill" : "star").foregroundStyle(col.isBest ? .yellow : Theme.secondaryText)
                            }
                            .buttonStyle(.borderless)
                            .help("Vote: best design")
                        }
                    }
                    .padding(12)
                    Divider()
                    Group {
                        if let html = extractHTML(col.output), col.phase == .done {
                            HTMLPreview(html: html)
                        } else if col.phase == .running || col.phase == .waiting {
                            VStack(spacing: 8) { SparkleSpinner(); Text(col.phase == .running ? "Generating..." : "Waiting...").foregroundStyle(Theme.secondaryText) }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Text(col.output.isEmpty ? "No output yet" : "No HTML in this answer.\nTry the UI designer preset.")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(6)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(col.isBest ? Color.yellow.opacity(0.8) : Theme.border, lineWidth: col.isBest ? 2 : 1))
            }
        }
        .padding(16)
    }
}

// MARK: - Stats

struct CompareStats: View {
    @Environment(AppState.self) private var state

    struct Point: Identifiable {
        var id: String { model + metric }
        var model: String
        var metric: String
        var value: Double
    }

    private var done: [(Int, CompareColumn)] {
        state.compareColumns.enumerated().filter { $0.element.stats != nil }.map { ($0.offset, $0.element) }
    }

    private var names: [String] { state.compareColumns.map { state.displayName($0) } }
    private var colors: [Color] { state.compareColumns.indices.map { Theme.seriesColor($0) } }

    var body: some View {
        if done.isEmpty {
            EmptyState(icon: "chart.bar", title: "No results yet", message: "Send a prompt to see speed, latency, token and memory comparisons.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    winners
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        chart("Generation speed", "tokens per second, higher is better") { $0.stats!.tokensPerSecond }
                        chart("Time to first token", "seconds, lower is better") { $0.stats!.timeToFirstToken }
                        chart("Output tokens", "how long each answer is") { Double($0.stats!.generationTokens) }
                        chart("Prompt tokens", "the same prompt in each model's tokenizer") { Double($0.promptTokenCount ?? $0.stats!.promptTokens) }
                        chart("Total time", "seconds for the whole answer") { $0.stats!.totalSeconds }
                        chart("Peak memory", "GB used while generating") { $0.stats!.peakMemoryGb }
                    }
                    table
                }
                .padding(18)
            }
        }
    }

    private var winners: some View {
        let fastest = done.max { $0.1.stats!.tokensPerSecond < $1.1.stats!.tokensPerSecond }
        let snappiest = done.min { $0.1.stats!.timeToFirstToken < $1.1.stats!.timeToFirstToken }
        let concise = done.filter { $0.1.stats!.generationTokens > 0 }.min { $0.1.stats!.generationTokens < $1.1.stats!.generationTokens }
        let lightest = done.min { $0.1.stats!.peakMemoryGb < $1.1.stats!.peakMemoryGb }
        return HStack(spacing: 12) {
            winner("Fastest", "hare", fastest, fastest.map { String(format: "%.0f tok/s", $0.1.stats!.tokensPerSecond) })
            winner("Quickest start", "bolt", snappiest, snappiest.map { String(format: "%.2fs", $0.1.stats!.timeToFirstToken) })
            winner("Most concise", "text.badge.minus", concise, concise.map { "\($0.1.stats!.generationTokens) tokens" })
            winner("Lightest", "memorychip", lightest, lightest.map { String(format: "%.1f GB", $0.1.stats!.peakMemoryGb) })
        }
    }

    private func winner(_ title: String, _ icon: String, _ item: (Int, CompareColumn)?, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 6) {
                Circle().fill(item.map { Theme.seriesColor($0.0) } ?? .gray).frame(width: 8, height: 8)
                Text(item.map { state.displayName($0.1) } ?? "-").font(.callout.weight(.semibold)).lineLimit(1)
            }
            Text(value ?? "").font(.title3.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12, padding: 12)
    }

    private func chart(_ title: String, _ subtitle: String, value: @escaping (CompareColumn) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText)
            Chart(done, id: \.1.id) { _, col in
                BarMark(x: .value("Value", value(col)), y: .value("Model", state.displayName(col)))
                    .foregroundStyle(by: .value("Model", state.displayName(col)))
                    .annotation(position: .trailing) {
                        Text(format(value(col))).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                    .cornerRadius(4)
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartLegend(.hidden)
            .frame(height: CGFloat(max(done.count, 1)) * 34 + 20)
        }
        .card()
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All metrics").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(["Model", "tok/s", "First token", "Out tokens", "Words", "Tokens/word", "Prompt tokens", "Total", "Memory", "Quality"], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    }
                }
                Divider()
                ForEach(done, id: \.1.id) { i, c in
                    let s = c.stats!
                    GridRow {
                        HStack(spacing: 6) { Circle().fill(Theme.seriesColor(i)).frame(width: 7, height: 7); Text(state.displayName(c)).lineLimit(1) }
                        Text(String(format: "%.1f", s.tokensPerSecond))
                        Text(String(format: "%.2fs", s.timeToFirstToken))
                        Text("\(s.generationTokens)")
                        Text("\(c.words)")
                        Text(c.words > 0 ? String(format: "%.2f", Double(s.generationTokens) / Double(c.words)) : "-")
                        Text("\(c.promptTokenCount ?? s.promptTokens)")
                        Text(String(format: "%.1fs", s.totalSeconds))
                        Text(String(format: "%.1f GB", s.peakMemoryGb))
                        Text(c.score.map { String(format: "%.1f", $0.overall) } ?? "-")
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
        .card()
    }

    private func format(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
    }
}

// MARK: - Quality

struct CompareQuality: View {
    @Environment(AppState.self) private var state

    struct Point: Identifiable {
        var id: String { model + criterion }
        var model: String
        var criterion: String
        var value: Double
    }

    private var scored: [(Int, CompareColumn, JudgeScore)] {
        state.compareColumns.enumerated().compactMap { i, c in c.score.map { (i, c, $0) } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                judgeCard
                if !scored.isEmpty {
                    scoresChart
                    ForEach(scored, id: \.1.id) { i, col, s in verdictCard(i, col, s) }
                }
                votes
            }
            .padding(18)
        }
    }

    private var judgeCard: some View {
        let judge = state.judgeSelection ?? state.largestModel
        let small = (judge?.model.sizeGb ?? 0) < 2.0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI judge").font(.headline)
                    Text("A local model grades each answer for accuracy, helpfulness and clarity.")
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text("Judge:").foregroundStyle(Theme.secondaryText)
                ModelPicker(selection: judge) { state.judgeSelection = $0 }
                Button(state.isJudging ? "Judging..." : "Score answers") { state.runJudge() }
                    .buttonStyle(.pillProminent)
                    .disabled(!state.canJudge)
            }
            if let status = state.judgeStatus {
                HStack(spacing: 8) { SparkleSpinner(); Text(status).foregroundStyle(Theme.secondaryText) }
            }
            if small {
                Label("Small judges (under about 4B parameters) often give every answer the same score. For a meaningful ranking, use the largest model you have, ideally 7B or more.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !state.canJudge && scored.isEmpty && !state.isJudging {
                Text("Run a comparison first, then score the answers here.").font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .card()
    }

    private var scoresChart: some View {
        let points = scored.flatMap { _, c, s in
            [("Accuracy", s.accuracy), ("Helpfulness", s.helpfulness), ("Clarity", s.clarity), ("Overall", s.overall)]
                .map { Point(model: state.displayName(c), criterion: $0.0, value: $0.1) }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Scores").font(.headline)
            Chart(points) { p in
                BarMark(x: .value("Criterion", p.criterion), y: .value("Score", p.value))
                    .foregroundStyle(by: .value("Model", p.model))
                    .position(by: .value("Model", p.model))
                    .cornerRadius(3)
            }
            .chartForegroundStyleScale(domain: state.compareColumns.map { state.displayName($0) },
                                       range: state.compareColumns.indices.map { Theme.seriesColor($0) })
            .chartYScale(domain: 0...10)
            .frame(height: 240)
        }
        .card()
    }

    private func verdictCard(_ i: Int, _ col: CompareColumn, _ s: JudgeScore) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 2) {
                Text(String(format: "%.1f", s.overall)).font(.system(size: 28, weight: .semibold, design: .serif))
                Text("of 10").font(.caption2).foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 64)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.seriesColor(i)).frame(width: 8, height: 8)
                    Text(state.displayName(col)).font(.headline)
                    if !s.parsed { Badge(text: "judge reply unclear", color: .orange) }
                }
                if !s.verdict.isEmpty { Text(s.verdict).font(.callout) }
                if let e = s.errors, !e.isEmpty, e.lowercased() != "none" {
                    Text("Issues: \(e)").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                HStack(spacing: 12) {
                    Text("Accuracy \(Int(s.accuracy))")
                    Text("Helpfulness \(Int(s.helpfulness))")
                    Text("Clarity \(Int(s.clarity))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
        }
        .card()
    }

    private var votes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your vote").font(.headline)
            Text("Pick the answer you think is best. Votes count toward the leaderboard.")
                .font(.caption).foregroundStyle(Theme.secondaryText)
            HStack(spacing: 8) {
                ForEach(Array(state.compareColumns.enumerated()), id: \.element.id) { i, col in
                    Button { state.markBest(col.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: col.isBest ? "star.fill" : "star").foregroundStyle(col.isBest ? .yellow : Theme.secondaryText)
                            Circle().fill(Theme.seriesColor(i)).frame(width: 7, height: 7)
                            Text(state.displayName(col))
                        }
                    }
                    .buttonStyle(.pill)
                    .disabled(col.phase != .done)
                }
            }
        }
        .card()
    }
}
