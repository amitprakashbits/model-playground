import Foundation

// MARK: - Backend payloads

struct LocalModel: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var repoId: String
    var path: String
    var source: String
    var architecture: String
    var modelType: String
    var quantized: Bool
    var engines: [String]
    var sizeBytes: Int64
    var context: Int

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
    var sizeGb: Double { Double(sizeBytes) / 1e9 }
}

struct CatalogEntry: Codable, Identifiable, Hashable {
    var family: String
    var repoId: String
    var params: String
    var sizeGb: Double
    var context: Int
    var engine: String
    var notes: String
    var id: String { repoId }
    var name: String { repoId.split(separator: "/").last.map(String.init) ?? repoId }
}

struct SearchResult: Codable, Identifiable, Hashable {
    var repoId: String
    var downloads: Int
    var likes: Int
    var id: String { repoId }
}

struct DownloadJob: Codable, Identifiable, Hashable {
    var jobId: String
    var repoId: String
    var path: String
    var status: String
    var downloaded: Int64
    var total: Int64
    var error: String?
    var id: String { jobId }

    var isActive: Bool { status == "starting" || status == "downloading" }
    var fraction: Double { total > 0 ? min(1, Double(downloaded) / Double(total)) : 0 }
}

struct SystemInfo: Codable, Hashable {
    var totalRamGb: Double
    var availableRamGb: Double
    var freeDiskGb: Double
}

struct GenerationStats: Codable, Hashable {
    var engine: String
    var promptTokens: Int
    var generationTokens: Int
    var tokensPerSecond: Double
    var promptTokensPerSecond: Double
    var timeToFirstToken: Double
    var totalSeconds: Double
    var peakMemoryGb: Double
    var finishReason: String?
}

struct JudgeScore: Codable, Hashable {
    var id: String
    var accuracy: Double
    var helpfulness: Double
    var clarity: Double
    var overall: Double
    var verdict: String
    var errors: String?
    var parsed: Bool
}

struct EvalResult: Codable, Hashable, Identifiable {
    var suite: String
    var id: String
    var category: String
    var label: String
    var expected: String
    var output: String
    var passed: Bool
    var contextTokens: Int
    var depth: Double
    var tokensPerSecond: Double
    var promptTokensPerSecond: Double
    var seconds: Double
    var peakMemoryGb: Double
}

/// One model's benchmark run.
struct BenchmarkRun: Codable, Hashable, Identifiable {
    var id = UUID()
    var date = Date()
    var model: String
    var modelPath: String
    var results: [EvalResult] = []
    var error: String?
    var finished = false

    var quiz: [EvalResult] { results.filter { $0.suite == "quick" } }
    var needle: [EvalResult] { results.filter { $0.suite == "needle" } }
    var quizScore: Double? { quiz.isEmpty ? nil : Double(quiz.filter(\.passed).count) / Double(quiz.count) }
    var needleScore: Double? { needle.isEmpty ? nil : Double(needle.filter(\.passed).count) / Double(needle.count) }
    /// Largest context length up to which every needle (at every shorter length too) was found.
    var maxReliableContext: Int? {
        let byLen = Dictionary(grouping: needle, by: { lengthBucket($0.contextTokens) })
        var best: Int?
        for len in byLen.keys.sorted() {
            guard byLen[len]!.allSatisfy(\.passed) else { break }
            best = len
        }
        return best
    }
}

func lengthBucket(_ tokens: Int) -> Int {
    let buckets = [1000, 2000, 4000, 8000, 16000, 32000, 64000, 128000]
    return buckets.min { abs($0 - tokens) < abs($1 - tokens) } ?? tokens
}

struct PromptPreset: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var icon: String
    var prompt: String

    static let all: [PromptPreset] = [
        PromptPreset(name: "Default", icon: "sparkle", prompt: ""),
        PromptPreset(name: "Concise", icon: "text.badge.minus", prompt: "Answer as briefly as possible while staying correct. No preamble."),
        PromptPreset(name: "Coder", icon: "chevron.left.forwardslash.chevron.right", prompt: "You are an expert software engineer. Write correct, idiomatic, well-structured code. Explain only what is non-obvious. Use fenced code blocks with a language tag."),
        PromptPreset(name: "Tutor", icon: "graduationcap", prompt: "You are a patient tutor. Explain step by step, check understanding with a short question at the end, and use simple examples."),
        PromptPreset(name: "Writer", icon: "pencil.line", prompt: "You are a skilled editor and writer. Write clearly and warmly, vary sentence length, and avoid clichés."),
        PromptPreset(name: "Analyst", icon: "chart.bar.doc.horizontal", prompt: "You are a careful analyst. Structure answers with headings and bullet points, state assumptions, and quantify where possible."),
        PromptPreset(name: "Document Q&A", icon: "doc.text.magnifyingglass", prompt: "Answer only from the attached documents. Quote the relevant passage, and say clearly when the documents don't contain the answer."),
    ]
}

// MARK: - App-side types

/// A model plus the engine it should run on.
struct ModelSelection: Codable, Hashable, Identifiable {
    var model: LocalModel
    var engine: String
    var id: String { model.path + "#" + engine }
    var label: String { engine == "airllm" ? "\(model.name) · AirLLM" : model.name }
    var shortLabel: String {
        model.name.replacingOccurrences(of: "-4bit", with: "").replacingOccurrences(of: "-MLX", with: "")
            .replacingOccurrences(of: "-OptiQ", with: "").replacingOccurrences(of: "-Instruct", with: "")
    }
}

struct GenParams: Codable, Hashable {
    var systemPrompt: String = ""
    var temperature: Double = 0.7
    var topP: Double = 1.0
    var maxTokens: Int = 4096
    var contextLimit: Int = 0
    var kvBits: Int = 0
    var thinking: Bool = true
}

struct Attachment: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var content: String
    var sizeBytes: Int
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id = UUID()
    var role: String          // "user" or "assistant"
    var content: String
    var attachments: [Attachment] = []
    var modelLabel: String? = nil
    var stats: GenerationStats? = nil
    var error: String? = nil
    var status: String? = nil  // transient, e.g. "Loading model..."
    var isStreaming = false

    /// What the model sees: attached files followed by the typed text.
    var promptContent: String {
        guard !attachments.isEmpty else { return content }
        let files = attachments.map { "<file name=\"\($0.name)\">\n\($0.content)\n</file>" }.joined(separator: "\n\n")
        return files + "\n\n" + content
    }
}

struct ChatSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = "New chat"
    var created = Date()
    var updated = Date()
    var selection: ModelSelection?
    var messages: [ChatMessage] = []
}

/// One completed generation, kept for the leaderboard.
struct RunRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var date = Date()
    var model: String
    var engine: String
    var source: String  // "chat" or "compare"
    var stats: GenerationStats
    var quality: Double?
    var wonVote = false
}

enum StreamEvent {
    case status(String)
    case loaded(Double)
    case token(String)
    case done(GenerationStats)
    case score(JudgeScore)
    case result(EvalResult)
    case error(String)
}

// MARK: - Helpers

enum Fit {
    case fits, tight, tooBig

    /// macOS lets the GPU use roughly two thirds of RAM on a 16 GB machine.
    static func estimate(sizeGb: Double, ramGb: Double) -> Fit {
        let need = sizeGb * 1.15 + 0.5
        if need < ramGb * 0.45 { return .fits }
        if need < ramGb * 0.68 { return .tight }
        return .tooBig
    }

    var label: String {
        switch self {
        case .fits: "Fits"
        case .tight: "Tight fit"
        case .tooBig: "Too big"
        }
    }

    /// The smallest common Mac memory size that runs a model of this size comfortably.
    static func requiredRam(sizeGb: Double) -> Int? {
        let need = (sizeGb * 1.15 + 0.5) / 0.68
        return [8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 512].first { Double($0) >= need }
    }
}

func formatContext(_ tokens: Int) -> String {
    if tokens <= 0 { return "?" }
    if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M" }
    if tokens >= 1000 {
        // Powers of two (32768) and round thousands (32000) both read as "32K".
        let k = tokens % 1024 == 0 ? tokens / 1024 : Int((Double(tokens) / 1000).rounded())
        return "\(k)K"
    }
    return "\(tokens)"
}

func formatCount(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}

/// Splits a reply into an optional reasoning part (<think>...</think>) and the visible answer.
func splitReasoning(_ text: String) -> (reasoning: String?, answer: String, thinking: Bool) {
    guard let start = text.range(of: "<think>") else {
        // A closing tag without an opening one: everything before it is reasoning.
        if let end = text.range(of: "</think>") {
            let reasoning = String(text[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning.isEmpty ? nil : reasoning, String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        return (nil, text, false)
    }
    let before = String(text[..<start.lowerBound])
    let after = text[start.upperBound...]
    if let end = after.range(of: "</think>") {
        let reasoning = String(after[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = (before + String(after[end.upperBound...])).trimmingCharacters(in: .whitespacesAndNewlines)
        return (reasoning.isEmpty ? nil : reasoning, answer, false)
    }
    return (String(after).trimmingCharacters(in: .whitespacesAndNewlines), before, true)
}

func wordCount(_ s: String) -> Int {
    s.split { $0.isWhitespace || $0.isNewline }.count
}
