import Charts
import SwiftUI

struct BenchmarksView: View {
    @Environment(AppState.self) private var state
    @State private var confirmClear = false

    /// Most recent run per model (runs are stored newest first).
    private var latest: [BenchmarkRun] {
        var seen = Set<String>()
        return state.benchmarkRuns.filter { !$0.results.isEmpty && seen.insert($0.model).inserted }
    }

    private var modelNames: [String] { latest.map(\.model) }
    private var colors: [Color] { latest.indices.map { Theme.seriesColor($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Benchmarks").font(.system(size: 28, design: .serif))
                    Text("Auto-graded tests run locally: a quick quiz for reasoning, knowledge, coding and instruction following, and a needle-in-a-haystack test that checks how well each model uses long context.")
                        .foregroundStyle(Theme.secondaryText)
                }
                setup
                if latest.isEmpty {
                    EmptyState(icon: "gauge.with.dots.needle.67percent", title: "No benchmark results yet",
                               message: "Pick one or more models above and run the suites.")
                        .frame(height: 220)
                } else {
                    summary
                    if latest.contains(where: { !$0.needle.isEmpty }) {
                        contextHeatmaps
                        contextCurves
                    }
                    if latest.contains(where: { !$0.quiz.isEmpty }) { quizMatrix }
                }
            }
            .padding(22)
        }
        .background(Theme.background)
        .navigationTitle("")
        .toolbar {
            ToolbarItem {
                Button { confirmClear = true } label: { Label("Clear Results", systemImage: "trash") }
                    .disabled(state.benchmarkRuns.isEmpty || state.isBenchmarking)
            }
        }
        .confirmationDialog("Clear all benchmark results?", isPresented: $confirmClear) {
            Button("Clear Results", role: .destructive) { state.clearBenchmarks() }
        }
    }

    // MARK: Setup

    private var setup: some View {
        @Bindable var state = state
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Models").font(.headline).frame(width: 90, alignment: .leading)
                ForEach(state.benchSelections) { sel in
                    HStack(spacing: 5) {
                        Text(sel.shortLabel).font(.callout.weight(.medium))
                        Button { state.benchSelections.removeAll { $0.id == sel.id } } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.secondaryText)
                        .disabled(state.isBenchmarking)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surfaceMuted, in: Capsule())
                }
                if state.benchSelections.count < 6 {
                    ModelPicker(selection: nil, placeholder: "Add model") { sel in
                        if !state.benchSelections.contains(where: { $0.id == sel.id }) { state.benchSelections.append(sel) }
                    }
                    .disabled(state.isBenchmarking)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 8) {
                Text("Suites").font(.headline).frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: suiteBinding("quick")) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Quick quiz")
                            Text("13 auto-graded questions: math, reasoning, knowledge, coding, instructions, language")
                                .font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Toggle(isOn: suiteBinding("needle")) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Long-context retrieval")
                            Text("Hides a passphrase at 10%, 50% and 90% depth in documents of growing length")
                                .font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if state.benchSuites.contains("needle") {
                        Picker("Up to", selection: $state.benchMaxContext) {
                            ForEach(AppState.needleLengthOptions, id: \.self) { n in Text("\(formatContext(n)) tokens").tag(n) }
                        }
                        .frame(width: 220)
                        .padding(.leading, 20)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(state.isBenchmarking)
                Spacer()
            }
            Divider()
            HStack(spacing: 10) {
                if let status = state.benchStatus {
                    SparkleSpinner()
                    Text(status).foregroundStyle(Theme.secondaryText).lineLimit(1)
                } else {
                    Text(estimate).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if state.isBenchmarking {
                    Button("Stop", action: state.stopBenchmarks).buttonStyle(.pill)
                } else {
                    Button { state.runBenchmarks() } label: { Label("Run benchmarks", systemImage: "play.fill") }
                        .buttonStyle(.pillProminent)
                        .disabled(state.benchSelections.isEmpty || state.benchSuites.isEmpty)
                }
            }
        }
        .card()
    }

    private var estimate: String {
        let n = state.benchSelections.count
        guard n > 0 else { return "Add models to benchmark. Models run one after another." }
        let needle = state.benchSuites.contains("needle")
            ? AppState.needleLengthOptions.filter { $0 <= state.benchMaxContext }.reduce(0, +) * 3 : 0
        return "\(n) model\(n == 1 ? "" : "s") · about \(formatContext(needle)) context tokens to process per model. Long contexts take minutes on small Macs."
    }

    private func suiteBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { state.benchSuites.contains(id) },
                set: { if $0 { state.benchSuites.insert(id) } else { state.benchSuites.remove(id) } })
    }

    // MARK: Summary

    private var summary: some View {
        struct Bar: Identifiable { var id: String { model + metric }; var model: String; var metric: String; var value: Double }
        let bars = latest.flatMap { r -> [Bar] in
            var out: [Bar] = []
            if let q = r.quizScore { out.append(Bar(model: r.model, metric: "Quiz", value: q * 100)) }
            if let n = r.needleScore { out.append(Bar(model: r.model, metric: "Context retrieval", value: n * 100)) }
            return out
        }
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Scores").font(.headline)
                Text("percent of tests passed").font(.caption).foregroundStyle(Theme.secondaryText)
                Chart(bars) { b in
                    BarMark(x: .value("Suite", b.metric), y: .value("Score", b.value))
                        .foregroundStyle(by: .value("Model", b.model))
                        .position(by: .value("Model", b.model))
                        .cornerRadius(3)
                        .annotation(position: .top) {
                            Text("\(Int(b.value))%").font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                        }
                }
                .chartForegroundStyleScale(domain: modelNames, range: colors)
                .chartYScale(domain: 0...110)
                .frame(height: 220)
            }
            .frame(maxWidth: .infinity)
            .card()
            VStack(alignment: .leading, spacing: 10) {
                Text("Results").font(.headline)
                ForEach(Array(latest.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.seriesColor(i)).frame(width: 8, height: 8)
                        Text(r.model).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        if let q = r.quizScore {
                            Text("Quiz \(r.quiz.filter(\.passed).count)/\(r.quiz.count)").font(.caption.monospacedDigit())
                                .foregroundStyle(q >= 0.8 ? .green : q >= 0.5 ? .orange : .red)
                        }
                        if !r.needle.isEmpty {
                            Text(r.maxReliableContext.map { "Reliable to \(formatContext($0))" } ?? "Context: failed")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(r.maxReliableContext != nil ? .green : .red)
                        }
                        if r.error != nil {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(r.error ?? "")
                        }
                    }
                }
                Text("Latest run per model. Earlier runs are kept in history.").font(.caption).foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 360)
            .card()
        }
    }

    // MARK: Context

    private var contextHeatmaps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Long-context retrieval").font(.headline)
            Text("Each cell is one test: green means the model found the hidden passphrase. Rows are where it was hidden.")
                .font(.caption).foregroundStyle(Theme.secondaryText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                ForEach(Array(latest.enumerated()).filter { !$0.element.needle.isEmpty }, id: \.element.id) { i, r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.seriesColor(i)).frame(width: 8, height: 8)
                            Text(r.model).font(.callout.weight(.semibold))
                        }
                        Chart(r.needle) { res in
                            RectangleMark(x: .value("Context", formatContext(lengthBucket(res.contextTokens))),
                                          y: .value("Depth", "\(Int(res.depth * 100))%"))
                                .foregroundStyle(res.passed ? Color.green.opacity(0.75) : Color.red.opacity(0.7))
                                .cornerRadius(4)
                                .annotation(position: .overlay) {
                                    Image(systemName: res.passed ? "checkmark" : "xmark")
                                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                }
                        }
                        .chartXAxisLabel("context length")
                        .frame(height: 150)
                    }
                    .padding(12)
                    .background(Theme.surfaceMuted.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .card()
    }

    private var contextCurves: some View {
        struct P: Identifiable { var id: String { model + "\(len)" }; var model: String; var len: Int; var speed: Double; var memory: Double }
        var points: [P] = []
        for r in latest {
            let groups: [Int: [EvalResult]] = Dictionary(grouping: r.needle) { lengthBucket($0.contextTokens) }
            for (len, rs) in groups {
                let speed = rs.map(\.promptTokensPerSecond).reduce(0, +) / Double(rs.count)
                let memory = rs.map(\.peakMemoryGb).max() ?? 0
                points.append(P(model: r.model, len: len, speed: speed, memory: memory))
            }
        }
        points.sort { $0.len < $1.len }
        return HStack(spacing: 14) {
            curve("Prompt processing speed", "tokens per second vs context length", points.map { ($0.model, $0.len, $0.speed) })
            curve("Peak memory", "GB vs context length", points.map { ($0.model, $0.len, $0.memory) })
        }
    }

    private func curve(_ title: String, _ subtitle: String, _ data: [(String, Int, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText)
            Chart(Array(data.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Context", p.1), y: .value("Value", p.2))
                    .foregroundStyle(by: .value("Model", p.0))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Context", p.1), y: .value("Value", p.2))
                    .foregroundStyle(by: .value("Model", p.0))
            }
            .chartForegroundStyleScale(domain: modelNames, range: colors)
            .chartXScale(type: .log)
            .chartXAxis {
                AxisMarks(values: AppState.needleLengthOptions) { v in
                    AxisGridLine()
                    AxisValueLabel { if let n = v.as(Int.self) { Text(formatContext(n)) } }
                }
            }
            .frame(height: 200)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    // MARK: Quiz

    private var quizMatrix: some View {
        let runs = latest.filter { !$0.quiz.isEmpty }
        let questions = runs.first?.quiz ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Text("Quiz answers").font(.headline)
            Text("Hover a cell to see what the model answered.").font(.caption).foregroundStyle(Theme.secondaryText)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Question").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Text("Expected").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    ForEach(Array(runs.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 4) {
                            Circle().fill(Theme.seriesColor(latest.firstIndex(of: r) ?? i)).frame(width: 7, height: 7)
                            Text(r.model).lineLimit(1)
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                Divider()
                ForEach(questions) { q in
                    GridRow {
                        HStack(spacing: 6) {
                            Badge(text: q.category)
                            Text(q.label).lineLimit(1).truncationMode(.tail).help(q.label)
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                        Text(q.expected).font(.caption.monospaced()).lineLimit(1)
                        ForEach(runs) { r in
                            if let res = r.quiz.first(where: { $0.id == q.id }) {
                                Image(systemName: res.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(res.passed ? .green : .red)
                                    .help("Answered: \(res.output)")
                            } else {
                                Text("-").foregroundStyle(Theme.secondaryText)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .card()
    }
}
