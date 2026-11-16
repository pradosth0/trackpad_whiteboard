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
        NSApp.activate(ignoringOtherApps: true)
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
        boardItem.submenu = boardMenu
        main.addItem(boardItem)

        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
