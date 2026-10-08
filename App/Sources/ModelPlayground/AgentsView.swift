import SwiftUI

struct AgentsView: View {
    @Environment(AppState.self) private var state
    @State private var editing: Agent?
    @FocusState private var promptFocused: Bool

    private var columns: [GridItem] {
        if state.agentColumns > 0 {
            return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: state.agentColumns)
        }
        return [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !state.lastAgentPrompt.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent)
                            Text(state.lastAgentPrompt).font(.callout).foregroundStyle(Theme.text).textSelection(.enabled)
                            Spacer()
                        }
                        .card(radius: 12, padding: 12)
                    }
                    if state.agentSynthesize && (state.synthOutput.phase != .idle || !state.synthOutput.text.isEmpty) {
                        SynthesisCard()
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Array(state.agents.enumerated()), id: \.element.id) { i, agent in
                            AgentCard(agent: agent, index: i, onEdit: { editing = agent })
                        }
                        if !state.isRunningAgents {
                            Button { state.addAgent() } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
                                    Text("Add agent").font(.callout.weight(.medium))
                                }
                                .frame(maxWidth: .infinity, minHeight: 180)
                                .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
            }
            composer
        }
        .background(Theme.background)
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Columns", selection: Bindable(state).agentColumns) {
                    Text("Auto").tag(0)
                    Text("2 columns").tag(2)
                    Text("3 columns").tag(3)
                    Text("4 columns").tag(4)
                }
                .help("Grid layout")
                Button { state.exportAgents() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(state.agentOutputs.values.allSatisfy { $0.text.isEmpty })
                    .help("Export the run as Markdown")
            }
        }
        .sheet(item: $editing) { agent in
            AgentEditor(agent: agent) { updated in
                if let i = state.agents.firstIndex(where: { $0.id == updated.id }) { state.agents[i] = updated; state.saveAgents() }
            }
        }
        .onAppear { if state.agents.isEmpty, let p = AgentTeamPreset.all.first { state.applyTeam(p) } }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var state = state
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents").font(.system(size: 22, design: .serif))
                let modelCount = Set(state.agents.compactMap { $0.selection?.id }).count
                Text("\(state.agents.count) agent\(state.agents.count == 1 ? "" : "s") · \(modelCount) model\(modelCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
            Menu {
                Section("Teams") {
                    ForEach(AgentTeamPreset.all) { p in
                        Button { state.applyTeam(p) } label: { Label("\(p.name): \(p.summary)", systemImage: p.icon) }
                    }
                }
                Divider()
                Button { state.applyModelShootout() } label: { Label("Model shootout: one agent per installed model", systemImage: "cpu") }
            } label: {
                Label("Load team", systemImage: "person.3.sequence.fill")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(state.isRunningAgents)
            Spacer()
            Picker("", selection: $state.agentMode) {
                ForEach(AgentMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .help(state.agentMode.help)
            .disabled(state.isRunningAgents)
            Toggle(isOn: $state.agentSynthesize) {
                Label("Synthesize", systemImage: "wand.and.rays")
            }
            .toggleStyle(.button)
            .help("A final agent merges every answer into one")
            .disabled(state.isRunningAgents)
            if state.agentSynthesize {
                ModelPicker(selection: state.synthSelection ?? state.largestModel, placeholder: "Lead model") { state.synthSelection = $0 }
                    .help("Model used by the synthesizer")
                    .disabled(state.isRunningAgents)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: Composer

    private var composer: some View {
        @Bindable var state = state
        return VStack(spacing: 8) {
            if state.isRunningAgents {
                HStack(spacing: 10) {
                    ProgressView(value: Double(state.agentProgress.done), total: Double(max(state.agentProgress.total, 1)))
                        .tint(Theme.accent)
                    Text("\(state.agentProgress.done) of \(state.agentProgress.total) done")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(state.agents.isEmpty ? "Add an agent first..." : "Give the team a task... (\(state.agentMode.rawValue.lowercased()) mode)",
                          text: $state.agentPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...8)
                    .focused($promptFocused)
                    .onSubmit(state.runAgents)
                if state.isRunningAgents {
                    Button(action: state.stopAgents) {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(Theme.text, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Stop the run")
                } else {
                    let ok = !state.agents.isEmpty && !state.agentPrompt.trimmingCharacters(in: .whitespaces).isEmpty
                    Button(action: state.runAgents) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Run team")
                        }
                        .font(.callout.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(ok ? Theme.accent : Theme.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ok)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Run every agent (⌘Return)")
                }
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(promptFocused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: promptFocused ? 1.5 : 1))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - Cards

struct AgentAvatar: View {
    var icon: String
    var color: Color
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct AgentCard: View {
    @Environment(AppState.self) private var state
    var agent: Agent
    var index: Int
    var onEdit: () -> Void
    @State private var hovering = false
    @State private var showPreview = false

    private var output: AgentOutput { state.agentOutputs[agent.id] ?? AgentOutput() }
    private var color: Color { Theme.seriesColor(agent.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AgentAvatar(icon: agent.icon, color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name).font(.headline).lineLimit(1)
                    Text(agent.role).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 4)
                phaseBadge
            }
            .padding(14)
            HStack(spacing: 6) {
                ModelPicker(selection: agent.selection) { sel in
                    if let i = state.agents.firstIndex(where: { $0.id == agent.id }) { state.agents[i].selection = sel; state.saveAgents() }
                }
                .disabled(state.isRunningAgents)
                Badge(text: String(format: "temp %.1f", agent.temperature), systemImage: "thermometer.medium")
                if let e = agent.selection?.engine, e == "airllm" { EngineBadge(engine: e) }
                Spacer()
                if !state.isRunningAgents {
                    Group {
                        Button(action: onEdit) { Image(systemName: "slider.horizontal.3") }.help("Edit agent")
                        Button { state.duplicateAgent(agent.id) } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate")
                        Button { state.removeAgent(agent.id) } label: { Image(systemName: "trash") }.help("Remove")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.secondaryText)
                    .opacity(hovering ? 1 : 0.55)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider()
            if showPreview, let html = extractHTML(output.text), output.phase == .done {
                HTMLPreview(html: html).frame(height: 340)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let status = output.status, output.text.isEmpty {
                        HStack(spacing: 8) {
                            if output.phase == .running { SparkleSpinner() } else { Image(systemName: "hourglass").foregroundStyle(Theme.secondaryText) }
                            Text(status).foregroundStyle(Theme.secondaryText)
                        }
                    }
                    if !output.text.isEmpty {
                        MessageContent(text: output.text, isStreaming: output.phase == .running, font: .system(size: 14))
                    }
                    if let e = output.error {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    }
                    if output.phase == .idle && output.text.isEmpty && output.error == nil {
                        Text("Ready").foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 340)
            }
            if let st = output.stats {
                Divider()
                HStack(spacing: 10) {
                    Label(String(format: "%.0f tok/s", st.tokensPerSecond), systemImage: "speedometer")
                    Label("\(st.generationTokens) tokens", systemImage: "number")
                    Label(String(format: "%.1fs", st.totalSeconds), systemImage: "timer")
                    Spacer()
                    if extractHTML(output.text) != nil {
                        Button { showPreview.toggle() } label: { Image(systemName: showPreview ? "text.alignleft" : "eye") }
                            .buttonStyle(.borderless).help(showPreview ? "Show text" : "Preview the generated page")
                    }
                    Button { copyToPasteboard(output.answer) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy answer")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(output.phase == .running ? color.opacity(0.85) : Theme.border, lineWidth: output.phase == .running ? 2 : 1)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 2).fill(color.gradient).frame(height: 3).padding(.horizontal, 16)
        }
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 12 : 6, y: hovering ? 4 : 2)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private var phaseBadge: some View {
        switch output.phase {
        case .running: Badge(text: "Working", color: color, systemImage: "bolt.fill")
        case .waiting: Badge(text: "Queued", systemImage: "clock")
        case .done where output.error != nil: Badge(text: "Error", color: .red, systemImage: "exclamationmark.triangle")
        case .done: Badge(text: "Done", color: .green, systemImage: "checkmark")
        case .idle: EmptyView()
        }
    }
}

struct SynthesisCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let o = state.synthOutput
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatar(icon: "wand.and.rays", color: Theme.accent, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Final answer").font(.system(size: 18, design: .serif))
                    Text("Synthesized from \(state.agents.count) agents by \((state.synthSelection ?? state.largestModel)?.shortLabel ?? "the lead model")")
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if let st = o.stats {
                    Text(String(format: "%.0f tok/s · %d tokens", st.tokensPerSecond, st.generationTokens))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
                if !o.answer.isEmpty {
                    Button { copyToPasteboard(o.answer) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                }
            }
            if let status = o.status, o.text.isEmpty {
                HStack(spacing: 8) {
                    if o.phase == .running { SparkleSpinner() } else { Image(systemName: "hourglass").foregroundStyle(Theme.secondaryText) }
                    Text(status).foregroundStyle(Theme.secondaryText)
                }
            }
            if !o.text.isEmpty { MessageContent(text: o.text, isStreaming: o.phase == .running) }
            if let e = o.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Theme.accentSoft, Theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent.opacity(0.35)))
    }
}

// MARK: - Editor

struct AgentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var agent: Agent
    var onSave: (Agent) -> Void

    private let icons = ["person.fill", "brain.head.profile", "wrench.and.screwdriver.fill", "lightbulb.fill", "lock.shield.fill",
                         "questionmark.bubble.fill", "ant.fill", "speedometer", "book.fill", "scissors", "checkmark.seal.fill",
                         "hand.thumbsup.fill", "hand.thumbsdown.fill", "scalemass.fill", "wand.and.stars", "hammer.fill",
                         "chart.bar.fill", "globe", "stethoscope", "graduationcap.fill", "paintbrush.fill", "cpu"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AgentAvatar(icon: agent.icon, color: Theme.seriesColor(agent.color), size: 44)
                TextField("Name", text: $agent.name).textFieldStyle(.roundedBorder).font(.title3)
            }
            Text("Icon").font(.caption).foregroundStyle(Theme.secondaryText)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 11), spacing: 6) {
                ForEach(icons, id: \.self) { ic in
                    Button { agent.icon = ic } label: {
                        Image(systemName: ic).frame(width: 30, height: 30)
                            .background(agent.icon == ic ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Color").font(.caption).foregroundStyle(Theme.secondaryText)
                ForEach(0..<4) { i in
                    Button { agent.color = i } label: {
                        Circle().fill(Theme.seriesColor(i)).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Theme.text, lineWidth: agent.color % 4 == i ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Role and instructions").font(.caption).foregroundStyle(Theme.secondaryText)
            TextEditor(text: $agent.role)
                .font(.callout)
                .frame(height: 110)
                .padding(6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            LabeledSlider(title: "Creativity (temperature)", value: $agent.temperature, range: 0...1.5, step: 0.05,
                          help: "Lower is focused and repeatable, higher is more varied")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(agent); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
