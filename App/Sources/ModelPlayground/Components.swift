import AppKit
import SwiftUI

// MARK: - Badges

struct Badge: View {
    var text: String
    var color: Color = Theme.secondaryText
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .foregroundStyle(color)
        .background(color.opacity(0.11), in: Capsule())
    }
}

struct EngineBadge: View {
    var engine: String
    var body: some View {
        Badge(text: engine == "airllm" ? "AirLLM" : "MLX",
              color: engine == "airllm" ? .purple : .blue,
              systemImage: engine == "airllm" ? "externaldrive" : "bolt.fill")
    }
}

struct FitBadge: View {
    var fit: Fit
    var sizeGb: Double = 0

    init(fit: Fit, sizeGb: Double = 0) {
        self.fit = fit
        self.sizeGb = sizeGb
    }

    var body: some View {
        switch fit {
        case .fits: Badge(text: fit.label, color: .green, systemImage: "checkmark.circle")
        case .tight: Badge(text: fit.label, color: .orange, systemImage: "exclamationmark.circle")
        case .tooBig:
            Badge(text: sizeGb <= 0 ? fit.label : Fit.requiredRam(sizeGb: sizeGb).map { "Needs \($0) GB Mac" } ?? "Too big for any Mac",
                  color: .red, systemImage: "xmark.circle")
        }
    }
}

// MARK: - Model picker

struct ModelPicker: View {
    @Environment(AppState.self) private var state
    var selection: ModelSelection?
    var placeholder = "Choose a model"
    var style: Style = .pill
    var onSelect: (ModelSelection) -> Void

    enum Style { case pill, plain }

    var body: some View {
        Menu {
            let mlx = state.selections.filter { $0.engine == "mlx" }
            let air = state.selections.filter { $0.engine == "airllm" }
            if mlx.isEmpty && air.isEmpty { Text("No models installed yet") }
            if !mlx.isEmpty {
                Section("MLX · fast") { ForEach(mlx) { s in item(s) } }
            }
            if !air.isEmpty {
                Section("AirLLM · streams from disk, slow") { ForEach(air) { s in item(s) } }
            }
            Divider()
            Button("Browse Model Library...") { state.sidebarSelection = .models }
        } label: {
            HStack(spacing: 5) {
                Text(selection?.shortLabel ?? placeholder).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, style == .pill ? 10 : 4)
            .padding(.vertical, 5)
            .background(style == .pill ? AnyShapeStyle(Theme.surfaceMuted) : AnyShapeStyle(Color.clear), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which model answers")
    }

    private func item(_ s: ModelSelection) -> some View {
        Button {
            onSelect(s)
        } label: {
            let detail = "\(s.model.sizeLabel)" + (s.model.context > 0 ? " · \(formatContext(s.model.context)) context" : "")
            if s.id == selection?.id {
                Label("\(s.shortLabel)   \(detail)", systemImage: "checkmark")
            } else {
                Text("\(s.shortLabel)   \(detail)")
            }
        }
    }
}

// MARK: - Stats

struct StatsSummary: View {
    var stats: GenerationStats
    @State private var showDetail = false

    var body: some View {
        Button { showDetail.toggle() } label: {
            HStack(spacing: 6) {
                Text(String(format: "%.0f tok/s", stats.tokensPerSecond))
                Text("·")
                Text("\(stats.generationTokens) tokens")
                Text("·")
                Text(String(format: "%.2fs", stats.totalSeconds))
                if stats.finishReason == "length" { Badge(text: "hit max tokens", color: .orange) }
                if stats.finishReason == "cancelled" { Badge(text: "stopped") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
        .buttonStyle(.plain)
        .help("Show generation details")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) { StatsDetail(stats: stats).padding(16) }
    }
}

struct StatsDetail: View {
    var stats: GenerationStats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            row("Generation speed", String(format: "%.1f tokens/s", stats.tokensPerSecond))
            row("Prompt processing", stats.promptTokensPerSecond > 0 ? String(format: "%.0f tokens/s", stats.promptTokensPerSecond) : "n/a")
            row("Time to first token", String(format: "%.2f s", stats.timeToFirstToken))
            row("Total time", String(format: "%.2f s", stats.totalSeconds))
            Divider()
            row("Prompt tokens", "\(stats.promptTokens)")
            row("Output tokens", "\(stats.generationTokens)")
            row("Peak memory", String(format: "%.2f GB", stats.peakMemoryGb))
            row("Engine", stats.engine == "airllm" ? "AirLLM" : "MLX")
            row("Finish reason", stats.finishReason ?? "n/a")
        }
        .font(.callout)
        .frame(minWidth: 260)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.secondaryText)
            Text(v).monospacedDigit().fontWeight(.medium)
        }
    }
}

// MARK: - Reasoning

struct ReasoningBlock: View {
    var text: String
    var thinking: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    if thinking {
                        Image(systemName: "sparkle").foregroundStyle(Theme.accent).symbolEffect(.pulse)
                    } else {
                        Image(systemName: "brain").foregroundStyle(Theme.secondaryText)
                    }
                    Text(thinking ? "Thinking..." : "Thought process")
                        .font(.callout.weight(.medium))
                    Text("\(wordCount(text)) words").font(.caption).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Divider()
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(Theme.surfaceMuted.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border))
    }
}

/// Model output: collapsible reasoning followed by rendered Markdown.
struct MessageContent: View {
    var text: String
    var isStreaming: Bool
    var font: Font = Theme.serif

    var body: some View {
        let parts = splitReasoning(text)
        VStack(alignment: .leading, spacing: 12) {
            if let reasoning = parts.reasoning {
                ReasoningBlock(text: reasoning, thinking: parts.thinking && isStreaming)
            }
            if !parts.answer.isEmpty {
                MarkdownView(text: parts.answer, font: font)
            }
        }
    }
}

/// Blinking block shown at the end of a reply while it streams.
struct StreamingCaret: View {
    @State private var on = true
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Theme.accent)
            .frame(width: 8, height: 16)
            .opacity(on ? 1 : 0.15)
            .onAppear { withAnimation(.easeInOut(duration: 0.55).repeatForever()) { on = false } }
    }
}

struct SparkleSpinner: View {
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .symbolEffect(.pulse)
    }
}

// MARK: - Generation settings

struct ParamsForm: View {
    @Environment(AppState.self) private var state

    private let contextOptions = [0, 2048, 4096, 8192, 16384, 32768, 65536, 131072]

    var body: some View {
        @Bindable var state = state
        Form {
            Section("System prompt") {
                Picker("Preset", selection: Binding(
                    get: { PromptPreset.all.first { $0.prompt == state.params.systemPrompt }?.name ?? "Custom" },
                    set: { name in if let p = PromptPreset.all.first(where: { $0.name == name }) { state.params.systemPrompt = p.prompt } }
                )) {
                    ForEach(PromptPreset.all) { p in Label(p.name, systemImage: p.icon).tag(p.name) }
                    if !PromptPreset.all.contains(where: { $0.prompt == state.params.systemPrompt }) { Text("Custom").tag("Custom") }
                }
                TextEditor(text: $state.params.systemPrompt)
                    .font(.callout)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
            }
            Section("Sampling") {
                LabeledSlider(title: "Temperature", value: $state.params.temperature, range: 0...2, step: 0.05,
                              help: "0 = deterministic, higher = more creative")
                LabeledSlider(title: "Top P", value: $state.params.topP, range: 0.05...1, step: 0.05,
                              help: "1 = off. Lower values restrict output to the most likely tokens.")
                Stepper(value: $state.params.maxTokens, in: 64...32768, step: 256) {
                    HStack { Text("Max output tokens"); Spacer(); Text("\(state.params.maxTokens)").monospacedDigit().foregroundStyle(.secondary) }
                }
                Toggle("Let reasoning models think", isOn: $state.params.thinking)
                    .help("Qwen 3 and similar hybrid models reason before answering. Turn off for faster, shorter replies.")
            }
            Section {
                Picker("KV cache", selection: $state.params.kvBits) {
                    Text("Full precision").tag(0)
                    Text("8-bit (half memory)").tag(8)
                    Text("4-bit (quarter memory)").tag(4)
                }
                Picker("Context window", selection: $state.params.contextLimit) {
                    ForEach(contextOptions, id: \.self) { n in
                        Text(n == 0 ? "Model maximum" : "\(formatContext(n)) tokens (sliding)").tag(n)
                    }
                }
                .disabled(state.params.kvBits != 0)
            } header: {
                Text("Long context")
            } footer: {
                Text("Memory grows with conversation length. A quantized KV cache lets bigger models hold longer chats. A sliding window caps memory by forgetting the oldest tokens; it can't be combined with a quantized cache. AirLLM always caps prompts at 512 tokens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to Defaults") { state.params = GenParams() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
    }
}

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
        .help(help)
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(Theme.secondaryText)
            Text(title).font(.system(size: 22, design: .serif))
            Text(message).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
