import Foundation

/// Recognition through the Claude Code command-line tool, which runs under the user's
/// Claude subscription instead of an API key.
///
/// One `claude` process is kept running and fed one picture at a time: starting a process
/// per line costs several seconds. Everything here runs on the main queue.
final class ClaudeCodeSession {
    static let shared = ClaudeCodeSession()

    typealias Completion = (Result<String, Recognizer.Failure>) -> Void

    /// The conversation grows with every line, so start a fresh process now and then.
    private let linesPerProcess = 15
    private let timeout: TimeInterval = 60

    private var process: Process?
    private var input: FileHandle?
    /// Model of the running process, and the one asked for by the latest line.
    private var model: Recognizer.Model?
    private var wanted = Recognizer.Model.fast
    private var buffer = Data()
    private var answered = 0

    private var waiting: [(png: Data, completion: Completion)] = []
    private var inFlight: Completion?
    private var requestToken = 0

    /// GUI apps do not get the shell's PATH, so look in the usual install locations too.
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let folders = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"] + path
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Starts the process ahead of the first line so that line does not pay for the startup.
    func warmUp(model: Recognizer.Model) {
        wanted = model
        if inFlight == nil, process == nil || self.model != model { _ = start(model: model) }
    }

    func recognize(png: Data, model: Recognizer.Model, completion: @escaping Completion) {
        wanted = model
        waiting.append((png, completion))
        pump()
    }

    private func pump() {
        guard inFlight == nil, !waiting.isEmpty else { return }
        if process != nil, answered >= linesPerProcess || model != wanted { stop() }
        if process == nil, let failure = start(model: wanted) {
            let all = waiting
            waiting = []
            all.forEach { $0.completion(.failure(failure)) }
            return
        }
        let next = waiting.removeFirst()
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png",
                                "data": next.png.base64EncodedString()]],
                    ["type": "text", "text": Recognizer.prompt],
                ],
            ],
        ]
        guard var line = try? JSONSerialization.data(withJSONObject: message), let input else {
            next.completion(.failure(.init(message: "could not send the line to Claude Code")))
            return
        }
        line.append(0x0A)
        inFlight = next.completion
        requestToken += 1
        let token = requestToken
        do {
            try input.write(contentsOf: line)
        } catch {
            finish(.failure(.init(message: "Claude Code stopped: \(error.localizedDescription)")))
            stop()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.inFlight != nil, self.requestToken == token else { return }
            self.stop()
            self.finish(.failure(.init(message: "Claude Code did not answer in time")))
        }
    }

    private func finish(_ result: Result<String, Recognizer.Failure>) {
        let completion = inFlight
        inFlight = nil
        completion?(result)
        pump()
    }

    private func start(model: Recognizer.Model) -> Recognizer.Failure? {
        stop()
        guard let executable = ClaudeCodeSession.executable() else {
            return .init(message: "the claude command was not found")
        }
        let task = Process()
        task.executableURL = executable
        task.arguments = [
            "-p", "--model", model == .accurate ? "opus" : "sonnet",
            // No tools, no extensions, nothing saved: this is a plain picture-in, text-out call.
            "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
            "--system-prompt", "You transcribe handwriting into LaTeX.",
            "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        ]
        task.currentDirectoryURL = FileManager.default.temporaryDirectory
        // Without the key in its environment the tool uses the subscription login.
        var environment = ProcessInfo.processInfo.environment
        environment["ANTHROPIC_API_KEY"] = nil
        task.environment = environment

        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, let task, self.process === task else { return }
                self.received(data)
            }
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.input = nil
                if self.inFlight != nil {
                    self.finish(.failure(.init(message: "Claude Code stopped unexpectedly")))
                }
            }
        }
        do {
            try task.run()
        } catch {
            return .init(message: "could not start Claude Code: \(error.localizedDescription)")
        }
        process = task
        input = stdin.fileHandleForWriting
        self.model = model
        buffer = Data()
        answered = 0
        return nil
    }

    /// Ends the current process; a new one starts with the next line.
    func stop() {
        guard let task = process else { return }
        process = nil
        (task.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        input = nil
        model = nil
        if task.isRunning { task.terminate() }
    }

    /// The tool prints one JSON event per line; the `result` event carries the answer.
    private func received(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  event["type"] as? String == "result", inFlight != nil else { continue }
            answered += 1
            let text = Recognizer.clean(event["result"] as? String ?? "")
            if event["is_error"] as? Bool == true || text.isEmpty {
                finish(.failure(.init(message: text.isEmpty ? "empty answer from Claude Code" : text)))
            } else {
                finish(.success(text))
            }
        }
    }
}
