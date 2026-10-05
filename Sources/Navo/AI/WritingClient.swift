import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to one language model of the local Navo engine (Gemma or Llama) through its
/// OpenAI-compatible chat endpoint. The request never leaves this Mac: the address is 127.0.0.1.
struct WritingClient: Sendable {
    /// The model's root, for example http://127.0.0.1:7861/gemma
    let baseURL: URL

    struct Answer: Sendable {
        var text: String
        /// "stop", or "length" when the answer reached its length limit.
        var finishReason = "stop"
        var promptTokens = 0
        var completionTokens = 0
        var tokensPerSecond: Double?
        /// The most memory the model used for this answer, weights included.
        var peakMemoryBytes: Int64?
    }

    struct Failure: LocalizedError {
        let message: String
        /// The HTTP status; 0 when the engine did not answer at all.
        var status = 0
        var errorDescription: String? { message }

        /// The text was longer than the model's context allows.
        var tooLong: Bool { status == 413 }
        /// The model is not on this Mac yet (or failed to load).
        var unavailable: Bool { status == 503 }
    }

    /// Asks the model to follow `system` on `user` and returns its answer. The answer arrives
    /// piece by piece: `onText` hears the text so far each time more of it is written.
    /// Cancelling the task stops the model at once.
    func write(
        system: String,
        user: String,
        temperature: Double,
        maxTokens: Int,
        onText: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> Answer {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        // The first piece can take a while: the speech models leave memory and this one loads.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": temperature,
            "max_tokens": maxTokens,
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure(message: "The local engine did not answer (\(error.localizedDescription)). Check that it is running in Settings.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 20_000 { break }
            }
            throw Failure(message: Self.detail(in: data) ?? "The local engine answered with error \(status).", status: status)
        }

        var answer = Answer(text: "")
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            if let error = json["error"] as? [String: Any] {
                throw Failure(message: error["message"] as? String ?? "The model stopped with an error.", status: 500)
            }
            if let choice = (json["choices"] as? [[String: Any]])?.first {
                if let piece = (choice["delta"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                    answer.text += piece
                    await onText?(answer.text)
                }
                if let reason = choice["finish_reason"] as? String {
                    answer.finishReason = reason
                }
            }
            if let usage = json["usage"] as? [String: Any] {
                answer.promptTokens = usage["prompt_tokens"] as? Int ?? 0
                answer.completionTokens = usage["completion_tokens"] as? Int ?? 0
            }
            if let stats = json["navo"] as? [String: Any] {
                answer.tokensPerSecond = (stats["tokens_per_second"] as? NSNumber)?.doubleValue
                answer.peakMemoryBytes = (stats["peak_memory_bytes"] as? NSNumber)?.int64Value
            }
        }
        try Task.checkCancellation()
        answer.text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return answer
    }

    /// The engine's own words for an error: {"detail": "..."}.
    private static func detail(in data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let detail = json["detail"] as? String { return detail }
        return (json["error"] as? [String: Any])?["message"] as? String
    }
}
