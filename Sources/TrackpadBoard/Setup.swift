import AppKit

/// The dialog that asks, on first launch, how handwriting should be recognized.
enum RecognitionSetup {
    private static let doneKey = "recognitionSetupDone"
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    static func run(for board: BoardView) {
        let claudeFound = ClaudeCodeSession.executable() != nil
        let hasKey = Recognizer.apiKey() != nil

        let alert = NSAlert()
        alert.messageText = "Set up handwriting recognition"
        alert.informativeText = """
        When you press Enter, the line you wrote can be sent to Claude and replaced by typeset text and math. \
        Choose how it is sent:

        • Claude subscription — through the Claude Code tool you are logged in to. About 4 seconds per line. \
        \(claudeFound ? "Claude Code was found on this Mac." : "Claude Code is not installed on this Mac yet.")

        • API key — straight to the Anthropic API. Faster, billed per line (about $0.003). \
        \(hasKey ? "A key is already saved." : "")

        Either way, a picture of each line leaves this Mac. You can change this later in Board > Recognition Setup…
        """
        alert.addButton(withTitle: "Use Claude Subscription")
        alert.addButton(withTitle: hasKey ? "Use API Key…" : "Enter API Key…")
        alert.addButton(withTitle: "Not Now")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !claudeFound { showInstallHelp() }
            board.setRecognition(enabled: true, viaClaudeCode: true)
        case .alertSecondButtonReturn:
            // Cancelling the key prompt leaves everything as it was, to be asked again next launch.
            guard askForKey(hasKey: hasKey) else { return }
            board.setRecognition(enabled: true, viaClaudeCode: false)
        default:
            board.setRecognition(enabled: false, viaClaudeCode: board.useClaudeCode)
        }
        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Returns true when a key is available afterwards.
    private static func askForKey(hasKey: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Anthropic API key"
        alert.informativeText = """
        Create a key at console.anthropic.com and paste it here. It is saved on this Mac only, in \
        ~/.config/trackpad-board/api_key, readable by your account alone.\
        \(hasKey ? "\n\nLeave the field empty to keep the key that is already saved." : "")
        """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return hasKey }
        do {
            try Recognizer.saveKey(key)
            return true
        } catch {
            let failure = NSAlert()
            failure.messageText = "The key could not be saved"
            failure.informativeText = error.localizedDescription
            failure.runModal()
            return false
        }
    }

    private static func showInstallHelp() {
        let alert = NSAlert()
        alert.messageText = "Claude Code is not installed yet"
        alert.informativeText = """
        Recognition will start working once Claude Code is installed and logged in:

        1. In Terminal, run:  \(installCommand)
        2. Run  claude  once and log in with your Claude account.
        3. Relaunch Trackpad Board.

        More at claude.com/claude-code
        """
        alert.addButton(withTitle: "Copy Install Command")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(installCommand, forType: .string)
        }
    }
}
