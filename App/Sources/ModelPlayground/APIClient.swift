import Foundation

struct APIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Talks to the local Python backend (backend/server.py).
struct APIClient {
    var port: Int

    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval = 30) async throws -> T {
        var req = URLRequest(url: url(path, query))
        req.timeoutInterval = timeout
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], timeout: TimeInterval = 60) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            throw APIError(message: (detail as? String) ?? "Server error \(http.statusCode)")
        }
    }

    struct Health: Decodable { var ok: Bool; var app: String?; var busy: Bool?; var loaded: [String]? }
    struct JobRef: Decodable { var jobId: String }
    struct OK: Decodable { var ok: Bool }
    struct TokenCounts: Decodable { var counts: [String: Int?]; var characters: Int; var words: Int }

    /// Succeeds only when the server on this port is our backend.
    func health() async throws -> Health {
        let h: Health = try await get("health", timeout: 2)
        guard h.app == "model-playground" else { throw APIError(message: "Port \(port) is used by another app") }
        return h
    }
    func system(folder: String) async throws -> SystemInfo { try await get("system", ["folder": folder]) }
    func catalog() async throws -> [CatalogEntry] { try await get("catalog") }
    func models(folder: String, includeHFCache: Bool) async throws -> [LocalModel] {
        try await get("models", ["folder": folder, "include_hf_cache": includeHFCache ? "true" : "false"])
    }
    func search(_ q: String, mlxOnly: Bool) async throws -> [SearchResult] {
        try await get("search", ["q": q, "mlx_only": mlxOnly ? "true" : "false"])
    }
    func downloads() async throws -> [DownloadJob] { try await get("downloads") }
    func download(repoId: String, folder: String) async throws -> String {
        let r: JobRef = try await post("download", ["repo_id": repoId, "folder": folder])
        return r.jobId
    }
    func convert(source: String, folder: String, bits: Int = 4) async throws -> String {
        let r: JobRef = try await post("convert", ["source": source, "folder": folder, "bits": bits])
        return r.jobId
    }
    func tokenize(paths: [String], text: String) async throws -> TokenCounts {
        try await post("tokenize", ["paths": paths, "text": text], timeout: 120)
    }
    func configure(idleUnloadSeconds: Int) async {
        _ = try? await post("config", ["idle_unload_seconds": idleUnloadSeconds]) as OK
    }
    func preload(_ selection: ModelSelection) async {
        _ = try? await post("preload", ["model_path": selection.model.path, "model_name": selection.shortLabel, "engine": selection.engine]) as OK
    }
    func stop() async { _ = try? await post("stop", [:]) as OK }
    func unload() async { _ = try? await post("unload", [:]) as OK }

    /// Streams a chat completion as newline-delimited JSON events.
    func chat(selection: ModelSelection, messages: [ChatMessage], params: GenParams) -> AsyncThrowingStream<StreamEvent, Error> {
        stream("chat", [
            "model_path": selection.model.path,
            "model_name": selection.shortLabel,
            "engine": selection.engine,
            "messages": messages.map { ["role": $0.role, "content": $0.promptContent] },
            "system_prompt": params.systemPrompt,
            "temperature": params.temperature,
            "top_p": params.topP,
            "max_tokens": params.maxTokens,
            "context_limit": params.contextLimit,
            "kv_bits": params.kvBits,
            "thinking": params.thinking,
        ])
    }

    /// Scores each answer with a local judge model.
    func judge(judge: ModelSelection, prompt: String, answers: [(id: String, text: String)]) -> AsyncThrowingStream<StreamEvent, Error> {
        stream("judge", [
            "judge_path": judge.model.path,
            "judge_name": judge.shortLabel,
            "engine": judge.engine,
            "prompt": prompt,
            "answers": answers.map { ["id": $0.id, "text": $0.text] },
        ])
    }

    /// Runs benchmark suites on one model, streaming one result per test.
    func evaluate(selection: ModelSelection, suites: [String], needleLengths: [Int], params: GenParams) -> AsyncThrowingStream<StreamEvent, Error> {
        stream("eval", [
            "model_path": selection.model.path,
            "model_name": selection.shortLabel,
            "engine": selection.engine,
            "suites": suites,
            "needle_lengths": needleLengths,
            "needle_depths": [0.1, 0.5, 0.9],
            "model_context": selection.model.context,
            "kv_bits": params.kvBits,
            "max_tokens": 256,
            "thinking": false,
        ])
    }

    private func stream(_ path: String, _ body: [String: Any]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: url(path))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 3600  // first AirLLM load can take a long time
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        try check(resp, data)
                    }
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        switch type {
                        case "status": continuation.yield(.status(obj["message"] as? String ?? ""))
                        case "loaded": continuation.yield(.loaded(obj["seconds"] as? Double ?? 0))
                        case "token": continuation.yield(.token(obj["text"] as? String ?? ""))
                        case "error": continuation.yield(.error(obj["message"] as? String ?? "Unknown error"))
                        case "result":
                            if let v = decode(EvalResult.self, obj["result"]) { continuation.yield(.result(v)) }
                        case "score":
                            if let v = decode(JudgeScore.self, obj["score"]) { continuation.yield(.score(v)) }
                        case "done":
                            if let v = decode(GenerationStats.self, obj["stats"]) { continuation.yield(.done(v)) }
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, let d = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? Self.decoder.decode(T.self, from: d)
    }
}
