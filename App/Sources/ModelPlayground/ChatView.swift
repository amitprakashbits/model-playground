import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppState.self) private var state
    var sessionId: UUID
    @State private var showInspector = false
    @FocusState private var composerFocused: Bool

    private var session: ChatSession? { state.sessions.first { $0.id == sessionId } }
    private var isGenerating: Bool { state.generatingSession == sessionId }

    var body: some View {
        Group {
            if let session {
                if session.messages.isEmpty {
                    welcome(session)
                } else {
                    conversation(session)
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(session?.messages.isEmpty == false ? (session?.title ?? "") : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.exportChat(sessionId) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export chat as Markdown")
                    .disabled(session?.messages.isEmpty ?? true)
                Button { state.newChat(with: session?.selection) } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .help("New chat (⌘N)")
                Button { showInspector.toggle() } label: { Label("Generation Settings", systemImage: "slider.horizontal.3") }
                    .help("Generation settings")
            }
        }
        .inspector(isPresented: $showInspector) {
            ParamsForm().inspectorColumnWidth(min: 270, ideal: 300, max: 380)
        }
        .onAppear { composerFocused = true }
    }

    // MARK: Welcome

    private func welcome(_ session: ChatSession) -> some View {
        VStack(spacing: 26) {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "sparkle").font(.system(size: 30)).foregroundStyle(Theme.accent)
                Text(greeting).font(Theme.greeting).foregroundStyle(Theme.text)
            }
            ChatComposer(sessionId: sessionId, focused: $composerFocused, isGenerating: isGenerating,
                         placeholder: "How can I help you today?")
                .frame(maxWidth: 700)
            if session.selection == nil {
                Button("Download a model to get started") { state.sidebarSelection = .models }.buttonStyle(.pillProminent)
            } else {
                SuggestionChips { text in
                    state.drafts[sessionId] = text
                    composerFocused = true
                }
                .frame(maxWidth: 700)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Hello, night owl" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty || h < 5 ? part : "\(part), \(first)"
    }

    // MARK: Conversation

    private func conversation(_ session: ChatSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(session.messages) { m in
                        MessageRow(message: m, isLast: m.id == session.messages.last?.id,
                                   canRegenerate: !isGenerating && state.generatingSession == nil,
                                   regenerate: { state.regenerate(in: sessionId) })
                            .id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .scrollContentBackground(.hidden)
            .onChange(of: session.messages.last?.content) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .safeAreaInset(edge: .bottom) {
                ChatComposer(sessionId: sessionId, focused: $composerFocused, isGenerating: isGenerating,
                             placeholder: "Reply to \(session.selection?.shortLabel ?? "the model")...")
                    .frame(maxWidth: 780)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 14)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                    )
            }
        }
    }
}

// MARK: - Messages

struct MessageRow: View {
    var message: ChatMessage
    var isLast: Bool
    var canRegenerate: Bool
    var regenerate: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 120)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        AttachmentChips(attachments: message.attachments)
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.system(size: 14.5))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let status = message.status, message.content.isEmpty {
                    HStack(spacing: 8) {
                        SparkleSpinner()
                        Text(status).foregroundStyle(Theme.secondaryText)
                    }
                }
                if !message.content.isEmpty {
                    MessageContent(text: message.content, isStreaming: message.isStreaming)
                }
                if message.isStreaming && !message.content.isEmpty && !splitReasoning(message.content).thinking {
                    StreamingCaret()
                }
                if let error = message.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if !message.isStreaming {
                    actions.opacity(hovering || isLast ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                copyToPasteboard(splitReasoning(message.content).answer)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy")
            if isLast {
                Button(action: regenerate) { Image(systemName: "arrow.counterclockwise") }
                    .disabled(!canRegenerate)
                    .help("Retry")
            }
            if let label = message.modelLabel {
                Text(label).font(.caption).foregroundStyle(Theme.secondaryText)
            }
            if let stats = message.stats { StatsSummary(stats: stats) }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.secondaryText)
        .font(.callout)
    }
}

struct AttachmentChips: View {
    var attachments: [Attachment]
    var onRemove: ((Attachment) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    HStack(spacing: 8) {
                        Image(systemName: a.name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.caption.weight(.medium)).lineLimit(1)
                            Text("\(formatCount(wordCount(a.content))) words").font(.caption2).foregroundStyle(Theme.secondaryText)
                        }
                        if let onRemove {
                            Button { onRemove(a) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                }
            }
        }
    }
}

// MARK: - Composer

struct ChatComposer: View {
    @Environment(AppState.self) private var state
    var sessionId: UUID
    var focused: FocusState<Bool>.Binding
    var isGenerating: Bool
    var placeholder: String
    @State private var dropTargeted = false

    private var session: ChatSession? { state.sessions.first { $0.id == sessionId } }
    private var draft: Binding<String> {
        Binding(get: { state.drafts[sessionId] ?? "" }, set: { state.drafts[sessionId] = $0 })
    }
    private var attachments: [Attachment] { state.pendingAttachments[sessionId] ?? [] }
    private var canSend: Bool {
        session?.selection != nil && state.generatingSession == nil
            && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        @Bindable var state = state
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                AttachmentChips(attachments: attachments) { a in
                    state.pendingAttachments[sessionId]?.removeAll { $0.id == a.id }
                }
            }
            TextField(placeholder, text: draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...12)
                .focused(focused)
                .onSubmit(send)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            HStack(spacing: 8) {
                Button { state.pickAttachments(for: sessionId) } label: {
                    Image(systemName: "paperclip").font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Theme.border))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .help("Attach files (text, code, Markdown, PDF). You can also drop files here.")
                Button { state.params.thinking.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                        Text("Think")
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .foregroundStyle(state.params.thinking ? Theme.accent : Theme.secondaryText)
                    .background(state.params.thinking ? Theme.accentSoft : Color.clear, in: Capsule())
                    .overlay(Capsule().stroke(state.params.thinking ? Color.clear : Theme.border))
                }
                .buttonStyle(.plain)
                .help("Let reasoning models (Qwen 3 and similar) think before answering")
                Spacer()
                ModelPicker(selection: session?.selection, style: .plain) { state.setSelection($0, for: sessionId) }
                if isGenerating {
                    Button(action: state.stopGenerating) {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(Theme.text, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .help("Stop (⌘.)")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(canSend ? Theme.accent : Theme.accent.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send (Return). Option-Return adds a new line.")
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(dropTargeted ? Theme.accent : Theme.border, lineWidth: dropTargeted ? 2 : 1))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in AppState.shared.addAttachments([url], to: sessionId) } }
                }
            }
            return true
        }
    }

    private func send() {
        guard canSend else { return }
        state.send(draft.wrappedValue, in: sessionId)
    }
}

struct SuggestionChips: View {
    var pick: (String) -> Void

    private let items: [(String, String, String)] = [
        ("pencil.line", "Write", "Write a short, warm thank-you note to a colleague who helped me ship a project."),
        ("graduationcap", "Learn", "Explain how attention in transformers works, with a simple analogy."),
        ("chevron.left.forwardslash.chevron.right", "Code", "Write a Swift function that debounces a closure, with a usage example."),
        ("doc.text.magnifyingglass", "Summarize", "Summarize the trade-offs of 4-bit vs 8-bit model quantization in a table."),
        ("lightbulb", "Brainstorm", "Give me 5 creative weekend project ideas using a Raspberry Pi."),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.1) { icon, title, prompt in
                Button { pick(prompt) } label: {
                    Label(title, systemImage: icon)
                }
                .buttonStyle(.pill)
            }
        }
    }
}
