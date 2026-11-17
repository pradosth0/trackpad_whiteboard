import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var board: BoardView!
    /// `--no-capture` starts without grabbing the cursor (click the board to capture).
    private let autoCapture = !CommandLine.arguments.contains("--no-capture")
    /// The file the board was opened from or last saved to.
    private var fileURL: URL?
    /// A file asked for (double-click in Finder) before the window existed.
    private var fileToOpenAtLaunch: URL?
    /// Where the board is kept between launches. `--autosave <path>` overrides it, and the
    /// typing self-test runs without one unless a path is given.
    private let autosaveURL: URL? = {
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--autosave"), arguments.count > i + 1 {
            return URL(fileURLWithPath: arguments[i + 1])
        }
        if arguments.contains("--type-test") { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TrackpadBoard/autosave.json")
    }()
    private var pendingAutosave: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSScreen.main?.visibleFrame.insetBy(dx: 60, dy: 40)
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        board = BoardView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = board
        window.delegate = self
        window.makeFirstResponder(board)
        board.onDirtyChange = { [weak self] in self?.updateTitle() }
        board.onChange = { [weak self] in self?.scheduleAutosave() }
        restoreAutosave()
        updateTitle()
        if let url = fileToOpenAtLaunch, confirmDiscardingChanges() { openBoard(at: url) }

        NSApp.mainMenu = makeMenu()
        window.makeKeyAndOrderFront(nil)
        if RecognitionSetup.isDone {
            board.warmUpRecognition()
        } else if !CommandLine.arguments.contains("--type-test") {
            // After the window is up, so the dialog appears over it.
            DispatchQueue.main.async { RecognitionSetup.run(for: self.board) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--type-test"), CommandLine.arguments.count > i + 1 {
            runTypeTest(prefix: CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
            // Developer check: save a picture of the board as it comes up, then quit.
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let rep = self.board.bitmapImageRepForCachingDisplay(in: self.board.bounds) {
                    self.board.cacheDisplay(in: self.board.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                print("title: \(self.window.title), unsaved: \(self.board.isDirty)")
                NSApp.terminate(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Autosave

    /// Writes the board shortly after the last change, so a burst of strokes costs one write.
    private func scheduleAutosave() {
        pendingAutosave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosave() }
        pendingAutosave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func autosave() {
        pendingAutosave?.cancel()
        pendingAutosave = nil
        guard let url = autosaveURL, board != nil else { return }
        let recovery = BoardFile.Recovery(board: board.snapshot(), documentPath: fileURL?.path,
                                          hasUnsavedChanges: board.isDirty)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(recovery).write(to: url, options: .atomic)
    }

    /// Brings back the board from the previous launch, including unsaved changes.
    private func restoreAutosave() {
        guard let url = autosaveURL, let data = try? Data(contentsOf: url),
              let recovery = try? JSONDecoder().decode(BoardFile.Recovery.self, from: data),
              recovery.board.version <= BoardFile.currentVersion else { return }
        board.load(recovery.board)
        var unsaved = recovery.hasUnsavedChanges
        if let path = recovery.documentPath {
            if FileManager.default.fileExists(atPath: path) {
                fileURL = URL(fileURLWithPath: path)
            } else {
                // Its file was moved or deleted: keep the content as an unsaved board.
                unsaved = true
            }
        }
        if unsaved { board.markDirty() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        if pendingAutosave != nil { autosave() }
    }

    // MARK: Files

    private func updateTitle() {
        window.title = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        window.representedURL = fileURL
        window.isDocumentEdited = board.isDirty
    }

    private var boardType: UTType { UTType(filenameExtension: BoardFile.fileExtension) ?? .json }

    private func show(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// Asks what to do with unsaved changes. Returns false when the user cancels.
    private func confirmDiscardingChanges() -> Bool {
        board.endEditing()
        guard board.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save the changes to this board?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn:
            board.markClean()
            return true
        default: return false
        }
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        board.endEditing()
        do {
            try board.snapshot().write(to: url)
        } catch {
            show(error, title: "The board could not be saved")
            return false
        }
        fileURL = url
        board.markClean()
        updateTitle()
        return true
    }

    @discardableResult
    private func save() -> Bool {
        if let url = fileURL { return write(to: url) }
        return saveAs()
    }

    @discardableResult
    private func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [boardType]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            + "." + BoardFile.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    @discardableResult
    private func openBoard(at url: URL) -> Bool {
        do {
            let failed = board.load(try BoardFile.read(from: url))
            fileURL = url
            updateTitle()
            if failed > 0 {
                let alert = NSAlert()
                alert.messageText = "\(failed) block\(failed == 1 ? "" : "s") could not be typeset and \(failed == 1 ? "was" : "were") left out"
                alert.runModal()
            }
            return true
        } catch {
            show(error, title: "The board could not be opened")
            return false
        }
    }

    @objc private func newBoard(_ sender: Any?) {
        guard confirmDiscardingChanges() else { return }
        board.load(BoardFile())
        fileURL = nil
        updateTitle()
    }

    @objc private func openDocument(_ sender: Any?) {
        guard confirmDiscardingChanges() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [boardType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openBoard(at: url)
    }

    @objc private func exportPDF(_ sender: Any?) { export(as: .pdf) { $0.exportPDF() } }
    @objc private func exportPNG(_ sender: Any?) { export(as: .png) { $0.exportPNG() } }

    /// Writes the .tex file and, next to it, one PDF per group of leftover ink.
    @discardableResult
    private func writeLaTeX(to url: URL) throws -> Bool {
        let prefix = url.deletingPathExtension().lastPathComponent
        guard let output = board.exportLaTeX(figurePrefix: prefix) else { return false }
        try output.tex.write(to: url, atomically: true, encoding: .utf8)
        for figure in output.figures {
            try figure.pdf.write(to: url.deletingLastPathComponent().appendingPathComponent(figure.name + ".pdf"),
                                 options: .atomic)
        }
        return true
    }

    @objc private func exportLaTeX(_ sender: Any?) {
        board.endEditing()
        guard board.exportLaTeX(figurePrefix: "") != nil else {
            let alert = NSAlert()
            alert.messageText = "There is nothing to export yet"
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tex") ?? .plainText]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".tex"
        panel.message = "Drawings are saved as PDF pictures next to the .tex file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeLaTeX(to: url)
        } catch {
            show(error, title: "The export could not be written")
        }
    }

    private func export(as type: UTType, render: (BoardView) -> Data?) {
        board.endEditing()
        guard let data = render(board) else {
            let alert = NSAlert()
            alert.messageText = "There is nothing to export yet"
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            + "." + (type.preferredFilenameExtension ?? "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            show(error, title: "The export could not be written")
        }
    }

    @objc private func saveDocument(_ sender: Any?) { save() }
    @objc private func saveDocumentAs(_ sender: Any?) { saveAs() }

    /// A board double-clicked in Finder, or dropped on the app.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        // The system also hands over file paths found among command-line flags; only boards count.
        guard url.pathExtension.lowercased() == BoardFile.fileExtension else { return false }
        guard board != nil else {
            fileToOpenAtLaunch = url
            return true
        }
        return confirmDiscardingChanges() && openBoard(at: url)
    }

    // Quitting does not ask about unsaved changes: the board comes back at the next launch.

    @objc private func showRecognitionSetup(_ sender: Any?) {
        RecognitionSetup.run(for: board)
    }

    func applicationWillTerminate(_ notification: Notification) {
        board.endEditing()
        autosave()
        ClaudeCodeSession.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowDidBecomeKey(_ notification: Notification) {
        if autoCapture { board.setCapture(true) }
    }

    func windowDidResignKey(_ notification: Notification) {
        board.setCapture(false)
    }

    /// Developer check: feeds synthetic keystrokes through the window, as if typed, and saves
    /// pictures of the board mid-typing (`<prefix>-typing.png`) and after (`<prefix>-done.png`).
    private func runTypeTest(prefix: String) {
        func press(_ characters: String, keyCode: UInt16 = 0) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode) else { return }
            window.sendEvent(event)
        }
        func type(_ text: String) { text.forEach { press(String($0)) } }
        func snapshot(_ name: String) {
            guard let rep = board.bitmapImageRepForCachingDisplay(in: board.bounds) else { return }
            board.cacheDisplay(in: board.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            type("the roots of $x^2+3x+3=0$ are complex")
            press("\r", keyCode: 36)
            type("$\\int_0^3 f(x) = \\frac{a}{b")
            snapshot("typing")
            type("}$")
            press("\r", keyCode: 36)
            type("cancelled")
            press("\u{1B}", keyCode: 53)
            snapshot("done")

            // Save, wipe, reopen: the board must come back identical.
            var saved = self.board.snapshot()
            saved.strokes.append((0..<40).flatMap { i -> [Double] in
                [300 + Double(i) * 6, ((420 + sin(Double(i) / 4) * 40) * 100).rounded() / 100]
            })
            let url = URL(fileURLWithPath: "\(prefix).tboard")
            try! saved.write(to: url)
            self.board.load(BoardFile())
            let emptied = self.board.snapshot()
            self.board.load(try! BoardFile.read(from: url))
            snapshot("reloaded")
            print("emptied: \(emptied.blocks.count) blocks, \(emptied.strokes.count) strokes")
            let reloaded = self.board.snapshot()
            print("round trip identical: \(reloaded == saved), dirty after load: \(self.board.isDirty)")
            defer { NSApp.terminate(nil) }
            if reloaded != saved {
                print("strokes \(reloaded.strokes == saved.strokes), blocks \(reloaded.blocks == saved.blocks),",
                      "zone \(reloaded.zoneOrigin == saved.zoneOrigin), camera \(reloaded.camera == saved.camera),",
                      "lines \(reloaded.previousLines == saved.previousLines)")
            }
            try? self.board.exportPDF()?.write(to: URL(fileURLWithPath: "\(prefix).pdf"))
            try? self.board.exportPNG()?.write(to: URL(fileURLWithPath: "\(prefix).png"))
            try? self.writeLaTeX(to: URL(fileURLWithPath: "\(prefix).tex"))
            // Save, edit, then save under a second name: the board must now belong to the second file.
            self.write(to: URL(fileURLWithPath: "\(prefix)-first.tboard"))
            type("edit between saves")
            press("\r", keyCode: 36)
            self.write(to: URL(fileURLWithPath: "\(prefix)-second.tboard"))
            print("after save as: title \(self.window.title), file \(self.fileURL?.lastPathComponent ?? "none"), unsaved \(self.board.isDirty)")
            // One more change, so a following launch can show that unsaved work is restored.
            type("typed after reload")
            press("\r", keyCode: 36)
        }
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Trackpad Board",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        func addFile(_ title: String, _ action: Selector, _ key: String,
                     _ mods: NSEvent.ModifierFlags = .command) {
            let item = fileMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
        }
        addFile("New", #selector(newBoard(_:)), "n")
        addFile("Open…", #selector(openDocument(_:)), "o")
        fileMenu.addItem(.separator())
        addFile("Save", #selector(saveDocument(_:)), "s")
        addFile("Save As…", #selector(saveDocumentAs(_:)), "s", [.command, .shift])
        fileMenu.addItem(.separator())
        addFile("Export as PDF…", #selector(exportPDF(_:)), "e")
        addFile("Export as PNG…", #selector(exportPNG(_:)), "e", [.command, .shift])
        addFile("Export as LaTeX…", #selector(exportLaTeX(_:)), "e", [.command, .option])
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Standard editing commands for the typing field.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let boardItem = NSMenuItem()
        let boardMenu = NSMenu(title: "Board")
        func add(_ title: String, _ action: Selector, _ key: String,
                 _ mods: NSEvent.ModifierFlags = .command) {
            let item = boardMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = board
        }
        add("Undo", #selector(BoardView.undoStroke(_:)), "z")
        add("Clear Board", #selector(BoardView.clearBoard(_:)), "\u{8}")
        boardMenu.addItem(.separator())
        add("Set Left Margin Here", #selector(BoardView.setMarginHere(_:)), "\r")
        add("Larger Zone", #selector(BoardView.growZone(_:)), "=")
        add("Smaller Zone", #selector(BoardView.shrinkZone(_:)), "-")
        boardMenu.addItem(.separator())
        add("Auto-continue Lines", #selector(BoardView.toggleAutoContinue(_:)), "a", [.command, .shift])
        boardMenu.items.last?.state = board.autoContinue ? .on : .off
        boardMenu.addItem(.separator())
        add("Recognize Lines on Enter", #selector(BoardView.toggleRecognize(_:)), "r", [.command, .shift])
        boardMenu.items.last?.state = board.recognizeOnEnter ? .on : .off
        add("Use Most Accurate Model", #selector(BoardView.toggleAccurateModel(_:)), "m", [.command, .shift])
        boardMenu.items.last?.state = board.useAccurateModel ? .on : .off
        add("Use Claude Code Subscription", #selector(BoardView.toggleClaudeCode(_:)), "k", [.command, .shift])
        boardMenu.items.last?.state = board.useClaudeCode ? .on : .off
        let setup = boardMenu.addItem(withTitle: "Recognition Setup…",
                                      action: #selector(showRecognitionSetup(_:)), keyEquivalent: "")
        setup.target = self
        boardItem.submenu = boardMenu
        main.addItem(boardItem)

        return main
    }
}

// Developer checks that need no trackpad:
//   --render-test <latex> <out.png>   typeset LaTeX to a picture
//   --ocr-test <line.png>...          send pictures through recognition and print the LaTeX
//                                     (add --claude-code for the subscription route, --accurate for Opus)
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--source-test"), arguments.count > i + 1 {
    // Typed form -> LaTeX -> typed form, and whether it renders.
    if arguments.contains("--from-latex") {
        print(Markup.source(fromLatex: arguments[i + 1]))
        exit(0)
    }
    let latex = Markup.latex(fromSource: arguments[i + 1])
    let ok = MathRenderer.image(latex: latex, fontSize: 24, color: .black) != nil
    print("\(latex)  |  back: \(Markup.source(fromLatex: latex))  |  \(ok ? "renders" : "RENDER FAILED")")
    exit(0)
}
if let i = arguments.firstIndex(of: "--render-test"), arguments.count > i + 2 {
    guard let item = Typeset(latex: arguments[i + 1], replacing: CGRect(x: 0, y: 0, width: 400, height: 60),
                             color: .black),
          let tiff = item.image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("render failed"); exit(1)
    }
    try! png.write(to: URL(fileURLWithPath: arguments[i + 2]))
    print("font size \(item.fontSize), size \(item.image.size)")
    exit(0)
}
if let i = arguments.firstIndex(of: "--ocr-test"), arguments.count > i + 1 {
    let files = arguments[(i + 1)...].filter { !$0.hasPrefix("--") }
    let model: Recognizer.Model = arguments.contains("--accurate") ? .accurate : .fast
    let viaClaudeCode = arguments.contains("--claude-code")
    let key = Recognizer.apiKey()
    if !viaClaudeCode, key == nil { print("no API key"); exit(1) }
    var remaining = files.count
    // All sent at once, as when lines are written faster than they are answered.
    for file in files {
        let png = try! Data(contentsOf: URL(fileURLWithPath: file))
        let started = Date()
        let done: (Result<String, Recognizer.Failure>) -> Void = { result in
            print(String(format: "%@  %.1fs ", (file as NSString).lastPathComponent,
                         Date().timeIntervalSince(started)), result)
            remaining -= 1
            if remaining == 0 { ClaudeCodeSession.shared.stop(); exit(0) }
        }
        if viaClaudeCode {
            ClaudeCodeSession.shared.recognize(png: png, model: model, completion: done)
        } else {
            Recognizer.recognize(png: png, model: model, key: key!, completion: done)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
