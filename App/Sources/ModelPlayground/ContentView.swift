import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            Group {
                switch state.serverState {
                case .running:
                    detail
                case .starting, .stopped:
                    VStack(spacing: 14) {
                        SparkleSpinner()
                        Text("Starting the model engine...").foregroundStyle(Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let msg):
                    BackendFailedView(message: msg)
                }
            }
            .background(Theme.background)
        }
        .tint(Theme.accent)
    }

    @ViewBuilder private var detail: some View {
        switch state.sidebarSelection {
        case .chat(let id): ChatView(sessionId: id).id(id)
        case .compare: CompareView()
        case .agents: AgentsView()
        case .benchmarks: BenchmarksView()
        case .leaderboard: LeaderboardView()
        case .models, .none: ModelsView()
        case .settings: SettingsView()
        }
    }
}

struct Sidebar: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var renaming: UUID?
    @State private var renameText = ""

    private var filtered: [ChatSession] {
        guard !search.isEmpty else { return state.sessions }
        return state.sessions.filter { s in
            s.title.localizedCaseInsensitiveContains(search) || s.messages.contains { $0.content.localizedCaseInsensitiveContains(search) }
        }
    }

    private var groups: [(String, [ChatSession])] {
        let cal = Calendar.current
        var buckets: [(String, [ChatSession])] = [("Today", []), ("Yesterday", []), ("Previous 7 days", []), ("Older", [])]
        for s in filtered {
            if cal.isDateInToday(s.updated) { buckets[0].1.append(s) }
            else if cal.isDateInYesterday(s.updated) { buckets[1].1.append(s) }
            else if s.updated > Date().addingTimeInterval(-7 * 86400) { buckets[2].1.append(s) }
            else { buckets[3].1.append(s) }
        }
        return buckets.filter { !$0.1.isEmpty }
    }

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Theme.accent)
                Text("Model Playground").font(.system(size: 17, weight: .medium, design: .serif))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)

            Button { state.newChat() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Theme.accent, in: Circle())
                    Text("New chat").font(.callout.weight(.medium)).foregroundStyle(Theme.text)
                    Spacer()
                    Text("⌘N").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondaryText)
                TextField("Search chats", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(Theme.secondaryText)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.surfaceMuted.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    navRow("Agents", "person.3.fill", .agents, tint: .purple)
                    navRow("Compare models", "rectangle.split.3x1.fill", .compare, tint: .blue)
                    navRow("Benchmarks", "gauge.with.dots.needle.67percent", .benchmarks, tint: .orange)
                    navRow("Leaderboard", "chart.bar.fill", .leaderboard, tint: .green)
                    navRow("Model library", "square.stack.3d.up.fill", .models, badge: state.models.count, tint: .gray)
                    ForEach(groups, id: \.0) { title, chats in
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 3)
                        ForEach(chats) { s in chatRow(s) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            StatusFooter()
        }
        .background(Theme.sidebar)
        .alert("Rename chat", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { if let id = renaming { state.renameChat(id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func navRow(_ title: String, _ icon: String, _ item: SidebarItem, badge: Int? = nil, tint: Color) -> some View {
        SidebarRow(selected: state.sidebarSelection == item, action: { state.sidebarSelection = item }) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(title)
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)").font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
            }
        }
    }

    private func chatRow(_ s: ChatSession) -> some View {
        SidebarRow(selected: state.sidebarSelection == .chat(s.id), action: { state.sidebarSelection = .chat(s.id) }) {
            HStack(spacing: 6) {
                if state.generatingSession == s.id {
                    Image(systemName: "sparkle").font(.caption).foregroundStyle(Theme.accent).symbolEffect(.pulse)
                }
                Text(s.title).lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .contextMenu {
            Button("Rename...") { renameText = s.title; renaming = s.id }
            Button("Export as Markdown...") { state.exportChat(s.id) }
            Divider()
            Button("Delete", role: .destructive) { state.deleteChat(s.id) }
        }
    }
}

/// Sidebar row with the app's own selection and hover styling.
struct SidebarRow<Content: View>: View {
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? Theme.accentSoft : (hovering ? Theme.surfaceMuted.opacity(0.7) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct StatusFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.loadedModel.map { "\($0) loaded" } ?? label)
                        .font(.caption.weight(.medium)).lineLimit(1)
                    if let s = state.system {
                        Text("\(Int(s.totalRamGb.rounded())) GB RAM · \(Int(s.freeDiskGb)) GB free")
                            .font(.caption2).foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Button { state.sidebarSelection = .settings } label: {
                    Image(systemName: "gearshape").foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.top, 2)
        }
    }

    private var color: Color {
        switch state.serverState {
        case .running: .green
        case .starting: .orange
        case .stopped: .gray
        case .failed: .red
        }
    }

    private var label: String {
        switch state.serverState {
        case .running: "Engine ready"
        case .starting: "Starting engine..."
        case .stopped: "Engine stopped"
        case .failed: "Engine error"
        }
    }
}

struct BackendFailedView: View {
    @Environment(AppState.self) private var state
    var message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 42, weight: .light)).foregroundStyle(Theme.accent)
            Text("The model engine isn't running").font(.system(size: 24, design: .serif))
            Text(message).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center).frame(maxWidth: 500)
            HStack(spacing: 10) {
                Button(state.isInstallingEnv ? "Installing..." : "Install Python Environment") { state.installEnvironment() }
                    .buttonStyle(.pillProminent)
                    .disabled(state.isInstallingEnv)
                Button("Choose Python...") { state.choosePython() }.buttonStyle(.pill)
                Button("Retry") { Task { await state.restartServer() } }.buttonStyle(.pill)
            }
            if state.isInstallingEnv { ProgressView().controlSize(.small) }
            if !state.serverLog.isEmpty {
                ScrollView {
                    Text(state.serverLog.suffix(5000)).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(maxWidth: 680, maxHeight: 220)
                .card(radius: 10, padding: 10)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
