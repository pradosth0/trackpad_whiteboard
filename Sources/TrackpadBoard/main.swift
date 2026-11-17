import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var board: BoardView!
    /// `--no-capture` starts without grabbing the cursor (click the board to capture).
    private let autoCapture = !CommandLine.arguments.contains("--no-capture")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSScreen.main?.visibleFrame.insetBy(dx: 60, dy: 40)
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Trackpad Board"
        window.isReleasedWhenClosed = false
        board = BoardView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = board
        window.delegate = self
        window.makeFirstResponder(board)

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
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showRecognitionSetup(_ sender: Any?) {
        RecognitionSetup.run(for: board)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            NSApp.terminate(nil)
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
