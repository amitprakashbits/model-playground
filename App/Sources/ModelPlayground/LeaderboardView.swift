import Charts
import SwiftUI

struct LeaderboardView: View {
    @Environment(AppState.self) private var state
    @State private var sortOrder = [KeyPathComparator(\Row.avgSpeed, order: .reverse)]
    @State private var confirmClear = false

    struct Row: Identifiable {
        var id: String { model }
        var model: String
        var engine: String
        var runs: Int
        var avgSpeed: Double
        var avgFirstToken: Double
        var avgTokens: Double
        var avgMemory: Double
        var quality: Double  // -1 when never judged
        var votes: Int
        var quiz: Double     // -1 when never benchmarked
        var context: Int     // largest reliable context, 0 when unknown
    }

    private var rows: [Row] {
        Dictionary(grouping: state.runs, by: \.model).map { model, runs in
            let q = runs.compactMap(\.quality)
            let n = Double(runs.count)
            return Row(model: model, engine: runs.last?.engine ?? "mlx", runs: runs.count,
                       avgSpeed: runs.map(\.stats.tokensPerSecond).reduce(0, +) / n,
                       avgFirstToken: runs.map(\.stats.timeToFirstToken).reduce(0, +) / n,
                       avgTokens: runs.map { Double($0.stats.generationTokens) }.reduce(0, +) / n,
                       avgMemory: runs.map(\.stats.peakMemoryGb).max() ?? 0,
                       quality: q.isEmpty ? -1 : q.reduce(0, +) / Double(q.count),
                       votes: runs.filter(\.wonVote).count,
                       quiz: state.latestBenchmark(for: model)?.quizScore.map { $0 * 100 } ?? -1,
                       context: state.latestBenchmark(for: model)?.maxReliableContext ?? 0)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            if state.runs.isEmpty {
                EmptyState(icon: "chart.bar.xaxis", title: "No runs yet",
                           message: "Every chat reply and comparison is recorded here, so you can see which models are fastest and best on your Mac.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summary
                        HStack(alignment: .top, spacing: 14) {
                            barChart("Average speed", "tokens per second") { $0.avgSpeed }
                            barChart("Average quality", "AI judge score out of 10") { max($0.quality, 0) }
                        }
                        table
                    }
                    .padding(18)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Leaderboard")
        .toolbar {
            ToolbarItem {
                Button { confirmClear = true } label: { Label("Clear History", systemImage: "trash") }
                    .disabled(state.runs.isEmpty)
            }
        }
        .confirmationDialog("Clear all recorded runs?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { state.clearRuns() }
        }
    }

    private var summary: some View {
        let all = rows
        return HStack(spacing: 12) {
            tile("Runs recorded", "\(state.runs.count)", "number")
            tile("Models tried", "\(all.count)", "square.stack.3d.up")
            tile("Fastest", all.max { $0.avgSpeed < $1.avgSpeed }.map { "\($0.model)" } ?? "-", "hare")
            tile("Highest quality", all.filter { $0.quality >= 0 }.max { $0.quality < $1.quality }?.model ?? "Not judged yet", "rosette")
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(Theme.secondaryText)
            Text(value).font(.system(size: 18, weight: .semibold, design: .serif)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12, padding: 12)
    }

    private func barChart(_ title: String, _ subtitle: String, value: @escaping (Row) -> Double) -> some View {
        let data = rows.sorted { value($0) > value($1) }.prefix(10)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText)
            Chart(Array(data)) { r in
                BarMark(x: .value("Value", value(r)), y: .value("Model", r.model))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing) {
                        Text(String(format: "%.1f", value(r))).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
            }
            .frame(height: CGFloat(max(data.count, 1)) * 30 + 20)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("All models").font(.headline)
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Model", value: \.model) { r in
                    HStack(spacing: 6) {
                        Text(r.model)
                        if r.engine == "airllm" { EngineBadge(engine: "airllm") }
                    }
                }
                .width(min: 160, ideal: 220)
                TableColumn("Runs", value: \.runs) { Text("\($0.runs)").monospacedDigit() }.width(50)
                TableColumn("Speed (tok/s)", value: \.avgSpeed) { Text(String(format: "%.1f", $0.avgSpeed)).monospacedDigit() }
                TableColumn("First token", value: \.avgFirstToken) { Text(String(format: "%.2fs", $0.avgFirstToken)).monospacedDigit() }
                TableColumn("Avg tokens", value: \.avgTokens) { Text(String(format: "%.0f", $0.avgTokens)).monospacedDigit() }
                TableColumn("Peak memory", value: \.avgMemory) { Text(String(format: "%.1f GB", $0.avgMemory)).monospacedDigit() }
                TableColumn("Quality", value: \.quality) { Text($0.quality >= 0 ? String(format: "%.1f", $0.quality) : "-").monospacedDigit() }
                TableColumn("Votes", value: \.votes) { Text("\($0.votes)").monospacedDigit() }.width(50)
                TableColumn("Quiz", value: \.quiz) { Text($0.quiz >= 0 ? String(format: "%.0f%%", $0.quiz) : "-").monospacedDigit() }.width(55)
                TableColumn("Reliable context", value: \.context) { Text($0.context > 0 ? formatContext($0.context) : "-").monospacedDigit() }
            }
            .frame(minHeight: CGFloat(min(rows.count, 12)) * 26 + 40)
            .scrollContentBackground(.hidden)
        }
        .card()
    }
}
