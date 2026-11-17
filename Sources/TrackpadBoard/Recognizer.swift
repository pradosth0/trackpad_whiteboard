import Foundation

/// Sends the picture of one handwritten line to Claude and gets LaTeX back.
enum Recognizer {
    enum Model: String {
        case fast = "claude-sonnet-5-5"
        case accurate = "claude-opus-5-5"
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let keyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/trackpad-board/api_key")

    /// The key comes from `ANTHROPIC_API_KEY` or, for the double-clicked app, from the key file.
    static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        guard let text = try? String(contentsOf: keyFile, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static let prompt = """
    This image is one line of handwriting from a whiteboard, written with a finger on a trackpad. \
    It is a math formula, plain words, or a mix of both.

    Transcribe it exactly as written into LaTeX math-mode source.
    - Output only the LaTeX: no $ or \\[ delimiters, no code fence, no explanation.
    - Do not correct, complete or simplify anything, and do not add symbols that are not written \
    (for example a missing dx after an integral).
    - Put plain words inside \\text{...}.
    - Use only common commands: \\frac, \\sqrt, \\int, \\sum, \\prod, \\lim, ^, _, \\left, \\right, \
    Greek letters, standard operators and relations, \\text, and \\mathrm{...} for named operators \
    such as Var.
    """

    /// Calls back on the main queue.
    static func recognize(png: Data, model: Model, key: String,
                          completion: @escaping (Result<String, Failure>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 2000,
            // A transcription needs no deliberation; low effort keeps the delay short.
            "output_config": ["effort": "low"],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png",
                                "data": png.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = parse(data: data, response: response, error: error)
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func parse(data: Data?, response: URLResponse?, error: Error?) -> Result<String, Failure> {
        if let error { return .failure(Failure(message: error.localizedDescription)) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        guard status == 200, let json else {
            let detail = (json?["error"] as? [String: Any])?["message"] as? String
            return .failure(Failure(message: "HTTP \(status)" + (detail.map { ": \($0)" } ?? "")))
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        let latex = clean(text)
        return latex.isEmpty ? .failure(Failure(message: "empty answer")) : .success(latex)
    }

    /// Strips a code fence or math delimiters if the model added them anyway.
    static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            var lines = s.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        where s.hasPrefix(open) && s.hasSuffix(close) && s.count >= open.count + close.count {
            s = String(s.dropFirst(open.count).dropLast(close.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return s
    }
}
