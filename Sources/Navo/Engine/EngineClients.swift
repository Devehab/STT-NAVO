import Foundation

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

private func checkHTTP(_ data: Data, _ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse else {
        throw EngineError(message: "No response from the engine")
    }
    guard (200..<300).contains(http.statusCode) else {
        var detail = String(decoding: data.prefix(400), as: UTF8.self)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["detail"] as? String {
                detail = text
            } else if let error = json["error"] as? [String: Any], let text = error["message"] as? String {
                detail = text
            } else if let text = json["error"] as? String {
                detail = text
            }
        }
        throw EngineError(message: "HTTP \(http.statusCode): \(detail)")
    }
}

/// multipart/form-data body with text fields and one audio file.
private func multipartBody(boundary: String, fields: [(String, String)], fileURL: URL) throws -> Data {
    var body = Data()
    for (name, value) in fields {
        body.appendString("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }
    let type = fileURL.pathExtension.lowercased() == "wav" ? "audio/wav" : "application/octet-stream"
    body.appendString("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: \(type)\r\n\r\n")
    body.append(try Data(contentsOf: fileURL))
    body.appendString("\r\n--\(boundary)--\r\n")
    return body
}

/// OpenAI-compatible speech-to-text client for one engine of the local Navo engine.
struct TranscriptionClient {
    /// The engine root, for example http://127.0.0.1:7861/audar
    let baseURL: URL

    struct Result {
        let text: String
        let backend: String?
        let processingMs: Int?
        /// Audio length in seconds, as the engine measured it.
        let duration: Double?
    }

    func transcribe(fileURL: URL, language: String) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        let boundary = "navo-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = try multipartBody(boundary: boundary, fields: [("language", language)], fileURL: fileURL)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try checkHTTP(data, response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError(message: "Unexpected response from the engine")
        }
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            text: text,
            backend: json["backend"] as? String,
            processingMs: json["processing_ms"] as? Int,
            duration: json["duration"] as? Double
        )
    }
}

/// Runs one recording through several speech engines: POST /v1/audio/compare
struct CompareClient {
    let baseURL: URL

    struct Entry: Identifiable, Equatable {
        let engine: String
        let name: String
        let text: String?
        let backend: String?
        let processingMs: Int?
        let error: String?

        var id: String { engine }
    }

    struct Result: Equatable {
        let duration: Double
        let entries: [Entry]
    }

    func compare(fileURL: URL, language: String, engines: [String]) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/compare"))
        request.httpMethod = "POST"
        request.timeoutInterval = 1200
        let boundary = "navo-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let fields = [("language", language), ("engines", engines.joined(separator: ","))]
        let body = try multipartBody(boundary: boundary, fields: fields, fileURL: fileURL)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try checkHTTP(data, response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else {
            throw EngineError(message: "Unexpected response from the engine")
        }
        let entries = results.map { item in
            Entry(
                engine: item["engine"] as? String ?? "",
                name: item["name"] as? String ?? "",
                text: (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                backend: item["backend"] as? String,
                processingMs: item["processing_ms"] as? Int,
                error: item["error"] as? String
            )
        }
        return Result(duration: json["duration"] as? Double ?? 0, entries: entries)
    }
}

/// OpenAI-compatible chat client (Navo engine, Ollama, LM Studio, llama.cpp server).
struct ChatClient {
    let baseURL: URL
    let model: String
    let timeout: TimeInterval

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": maxTokens,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(data, response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw EngineError(message: "Unexpected response from the cleanup model")
        }
        return content
    }
}
