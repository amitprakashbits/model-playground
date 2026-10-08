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
        HStack(spacing: 0) {
            Group {
                if let session {
                    if session.messages.isEmpty {
                        welcome(session)
                    } else {
                        conversation(session)
                    }
                }
            }
            .frame(minWidth: 420)
            if let html = state.canvasHTML {
                Divider()
                CanvasPane(html: html)
                    .frame(minWidth: 380, idealWidth: 620, maxWidth: .infinity)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.canvasHTML != nil)
        .background(Theme.background)
        .navigationTitle(session?.messages.isEmpty == false ? (session?.title ?? "") : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { state.exportChat(sessionId) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export chat as Markdown")
                    .disabled(session?.messages.isEmpty ?? true)
                Button { state.newChat(with: session?.selection) } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .help("New chat (⌘N)")
                Button {
                    if state.canvasHTML != nil { state.canvasHTML = nil }
                    else { state.canvasHTML = session?.messages.reversed().lazy.compactMap { extractHTML($0.content) }.first ?? Self.emptyCanvas }
                } label: { Label("Canvas", systemImage: state.canvasHTML == nil ? "rectangle.righthalf.inset.filled" : "rectangle.righthalf.inset.filled.arrow.right") }
                    .help("Show or hide the design canvas")
                Button { showInspector.toggle() } label: { Label("Generation Settings", systemImage: "slider.horizontal.3") }
                    .help("Generation settings")
            }
        }
        .inspector(isPresented: $showInspector) {
            ParamsForm().inspectorColumnWidth(min: 270, ideal: 300, max: 380)
        }
        .onAppear {
            composerFocused = true
            state.preload(session?.selection)
        }
    }

    static let emptyCanvas = "<html><body style='font-family:-apple-system;display:grid;place-items:center;height:100vh;margin:0;color:#888;background:#faf9f5'><div style='text-align:center'><div style='font-size:42px'>🎨</div><p>Ask for a page, screen or component and it renders here.<br>Tip: pick the <b>UI designer</b> preset in settings.</p></div></body></html>"

    // MARK: Welcome

    private func welcome(_ session: ChatSession) -> some View {
        VStack(spacing: 26) {
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "sparkle").font(.system(size: 30)).foregroundStyle(Theme.accent)
                Text(greeting).font(Theme.greeting).foregroundStyle(Theme.text)
            }
            ChatComposer(sessionId: sessionId, focused: $composerFocused, isGenerating: isGenerating, selection: session.selection,
                         placeholder: "How can I help you today?")
                .frame(maxWidth: 700)
            if session.selection?.engine == "airllm" {
                Label("Running on AirLLM: about 0.2 tokens per second, prompts capped at 512 tokens", systemImage: "externaldrive")
                    .font(.caption).foregroundStyle(.purple)
            }
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
                                   regenerate: { state.regenerate(in: sessionId) },
                                   edit: { state.editMessage(m.id, in: sessionId); composerFocused = true })
                            .equatable()
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
                ChatComposer(sessionId: sessionId, focused: $composerFocused, isGenerating: isGenerating, selection: session.selection,
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

struct MessageRow: View, Equatable {
    /// Rows only re-render when their own message changes, not on every streamed token elsewhere.
    nonisolated static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message == b.message && a.isLast == b.isLast && a.canRegenerate == b.canRegenerate
    }

    @Environment(AppState.self) private var state
    var message: ChatMessage
    var isLast: Bool
    var canRegenerate: Bool
    var regenerate: () -> Void
    var edit: () -> Void = {}
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        if message.role == "user" {
            HStack(alignment: .top) {
                Spacer(minLength: 120)
                if hovering && canRegenerate {
                    Button(action: edit) { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.secondaryText)
                        .help("Edit and resend from here")
                        .padding(.top, 10)
                }
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
            .onHover { hovering = $0 }
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
                    actions.opacity(hovering || isLast ? 1 : 0.45)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Copy Reply", action: copyReply)
                Button("Copy as Markdown") { copyToPasteboard(message.content) }
                if let html = extractHTML(message.content) {
                    Button("Copy HTML") { copyToPasteboard(html) }
                }
            }
        }
    }

    private func copyReply() {
        copyToPasteboard(splitReasoning(message.content).answer)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(action: copyReply) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help("Copy the reply (without the thought process)")
            if let html = extractHTML(message.content) {
                Button { state.canvasHTML = html } label: { Label("Preview", systemImage: "eye") }
                    .help("Open the generated page in the canvas")
            }
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
    /// Passed in rather than read from `state.sessions`, so streamed tokens don't re-render the composer.
    var selection: ModelSelection?
    var placeholder: String
    @State private var dropTargeted = false
    /// Typing stays local to this view; shared state is only touched on send or when leaving the chat.
    @State private var text = ""

    private var draft: Binding<String> { $text }
    private var attachments: [Attachment] { state.pendingAttachments[sessionId] ?? [] }
    private var canSend: Bool {
        selection != nil && state.generatingSession == nil
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
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
                Menu {
                    Button { state.pickAttachments(for: sessionId) } label: { Label("Attach files...", systemImage: "doc") }
                    Button { state.pickFolder(for: sessionId) } label: { Label("Attach folder...", systemImage: "folder") }
                } label: {
                    Image(systemName: "paperclip").font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Theme.border))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.secondaryText)
                .help("Attach files or a whole folder (text, code, Markdown, PDF). You can also drop files here.")
                Menu {
                    if state.savedPrompts.isEmpty { Text("No saved prompts yet") }
                    ForEach(state.savedPrompts, id: \.self) { p in
                        Button(String(p.prefix(70))) { state.drafts[sessionId] = p }
                    }
                    Divider()
                    Button("Save Current Prompt") {
                        let d = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !d.isEmpty && !state.savedPrompts.contains(d) { state.savedPrompts.insert(d, at: 0) }
                    }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !state.savedPrompts.isEmpty {
                        Menu("Delete") {
                            ForEach(state.savedPrompts, id: \.self) { p in
                                Button(String(p.prefix(70))) { state.savedPrompts.removeAll { $0 == p } }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "bookmark").font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Theme.border))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.secondaryText)
                .help("Saved prompts")
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
                if let sel = selection, sel.model.engines.count > 1 {
                    EngineSwitch(engine: sel.engine) { e in
                        state.setSelection(ModelSelection(model: sel.model, engine: e), for: sessionId)
                    }
                    .disabled(isGenerating)
                }
                ModelPicker(selection: selection, style: .plain) { state.setSelection($0, for: sessionId) }
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
        .onAppear { text = state.drafts[sessionId] ?? "" }
        // Suggestion chips, edit-and-resend and saved prompts fill the box through `drafts`.
        .onChange(of: state.drafts[sessionId]) { _, new in
            if let new, new != text { text = new }
        }
        .onDisappear { state.drafts[sessionId] = text.isEmpty ? nil : text }
    }

    private func send() {
        guard canSend else { return }
        let message = text
        text = ""
        state.drafts[sessionId] = nil
        state.send(message, in: sessionId)
    }
}

/// MLX / AirLLM toggle for models that run on both engines.
struct EngineSwitch: View {
    var engine: String
    var onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("mlx", "MLX", "bolt.fill", "Fast: whole model in memory")
            segment("airllm", "AirLLM", "externaldrive", "Streams one layer at a time from disk: low memory, very slow, 512-token prompts")
        }
        .padding(2)
        .background(Theme.surfaceMuted, in: Capsule())
    }

    private func segment(_ id: String, _ title: String, _ icon: String, _ help: String) -> some View {
        Button { onChange(id) } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .foregroundStyle(engine == id ? Color.white : Theme.secondaryText)
                .background(engine == id ? (id == "airllm" ? Color.purple : Color.blue) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SuggestionChips: View {
    var pick: (String) -> Void

    private let items: [(String, String, String)] = [
        ("paintbrush.pointed", "Design", "Design a modern landing page for a local AI app called Model Playground: hero, three feature cards, pricing and footer. One self-contained HTML file with Tailwind."),
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
