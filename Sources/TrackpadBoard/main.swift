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
        board.warmUpRecognition()
        NSApp.activate(ignoringOtherApps: true)
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

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Trackpad Board",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

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
