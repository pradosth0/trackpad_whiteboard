import AppKit

/// One continuous finger contact, in board (world) coordinates.
struct Stroke {
    private static var nextID = 0

    /// Stable identity: indices shift when recognized lines are replaced.
    let id: Int
    var points: [CGPoint]
    private(set) var path: CGPath
    private(set) var bounds: CGRect

    init(start: CGPoint) {
        Stroke.nextID += 1
        id = Stroke.nextID
        points = [start]
        path = Stroke.makePath([start])
        bounds = path.boundingBoxOfPath
    }

    mutating func append(_ p: CGPoint) {
        points.append(p)
        path = Stroke.makePath(points)
        bounds = path.boundingBoxOfPath
    }

    /// Smooths the polyline with quadratic curves through segment midpoints.
    private static func makePath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        if pts.count == 1 {
            // A tap: draw a dot.
            path.addEllipse(in: CGRect(x: first.x - 0.6, y: first.y - 0.6, width: 1.2, height: 1.2))
            return path
        }
        path.move(to: first)
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }
}

final class BoardView: NSView, NSTextFieldDelegate {
    // MARK: Tunables

    /// How far Enter moves the zone down when the line has no ink, as a fraction of the zone height.
    var lineStepFraction: CGFloat = 0.5
    /// Ink ending in the right part of the zone (past this fraction) arms auto-continuation...
    private let continueRightEdge: CGFloat = 0.8
    /// ...and a following touch in the left part (before this fraction) triggers it.
    private let continueLeftEdge: CGFloat = 0.3
    /// When on, writing to the right end and returning left continues the same line.
    private(set) var autoContinue = true
    /// Space kept between the zone and the window edge when the camera follows.
    private let cameraMargin: CGFloat = 40
    private let strokeWidth: CGFloat = 2.2

    // MARK: Board state (world coordinates, y grows downward)

    private var strokes: [Stroke] = []
    private var current: Stroke?
    /// Recognized lines, typeset in place of their handwriting.
    private var typeset: [Typeset] = []
    private enum UndoItem {
        case stroke
        case clear([Stroke], [Typeset])
        /// A block was typed, edited or deleted; undo puts back what it was (nil: it did not exist).
        case block(id: Int, previous: Typeset?)
        /// A line was replaced by typeset math; undo puts the handwriting back.
        case recognized(ink: [(index: Int, stroke: Stroke)], typesetID: Int)
    }
    private var undoStack: [UndoItem] = []

    // MARK: Typing and editing state

    /// The block being typed or edited in the field at the bottom of the window.
    private struct Edit {
        let id: Int
        /// The block before editing; nil when it is being typed from scratch.
        let original: Typeset?
        let fontSize: CGFloat
        var placement: Typeset.Placement
        /// False while the field holds something that cannot be typeset.
        var valid = true
    }
    private var edit: Edit?
    private let typedFontSize: CGFloat = 24
    /// Blocks typed on the line being written; they count as its content, like ink.
    private var lineBlockIDs: [Int] = []
    /// When and where the current hover touch began, to tell a tap from a look-around.
    private var hoverStart: (time: Date, norm: CGPoint)?
    private var hoverTravel: CGFloat = 0
    private lazy var field: NSTextField = {
        let field = NSTextField(frame: .zero)
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.placeholderString = "Text, with math between $…$"
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.isHidden = true
        addSubview(field)
        return field
    }()

    // MARK: Recognition state

    /// When on, Enter sends the finished line to be recognized and typeset.
    private(set) var recognizeOnEnter = UserDefaults.standard.object(forKey: "recognizeOnEnter") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recognizeOnEnter, forKey: "recognizeOnEnter") }
    }
    /// Slower and about twice the price, but misreads fewer symbols.
    private(set) var useAccurateModel = UserDefaults.standard.bool(forKey: "useAccurateModel") {
        didSet { UserDefaults.standard.set(useAccurateModel, forKey: "useAccurateModel") }
    }
    /// Recognize through the Claude Code tool (Claude subscription) instead of an API key.
    /// Defaults to on when no API key is set up.
    private(set) var useClaudeCode = UserDefaults.standard.object(forKey: "useClaudeCode") as? Bool
        ?? (Recognizer.apiKey() == nil) {
        didSet { UserDefaults.standard.set(useClaudeCode, forKey: "useClaudeCode") }
    }
    private var model: Recognizer.Model { useAccurateModel ? .accurate : .fast }
    /// Strokes of lines that were sent and not answered yet.
    private var pendingStrokes: Set<Int> = []
    private var pendingLines = 0
    /// Short message under the board (errors, missing key).
    private var notice: String?
    private var noticeToken = 0
    private var warnedAboutSetup = false

    /// Top-left of the trackpad zone on the board.
    private var padOrigin = CGPoint.zero
    private var padWidth: CGFloat = 560
    /// Width / height of the physical trackpad; refined from the first touch.
    private var padAspect: CGFloat = 1.6
    /// Where Enter returns the zone to horizontally.
    private var marginX: CGFloat = 0
    /// World coordinate shown at the view's top-left corner.
    private var camera = CGPoint(x: -40, y: -40)
    /// Index of the first stroke belonging to the line being written.
    private var lineStart = 0
    /// Zone positions of previous lines, so Shift+Enter can go back.
    private var lineHistory: [(origin: CGPoint, lineStart: Int)] = []
    /// Point picked in precision mode; the next touch lands exactly here.
    private var anchor: CGPoint?
    /// The anchor was only previewed by pressing Control and has not been moved yet.
    private var anchorIsPreview = false

    private var padRect: CGRect {
        CGRect(x: padOrigin.x, y: padOrigin.y, width: padWidth, height: padWidth / padAspect)
    }

    // MARK: Touch state

    private enum Mode { case idle, draw, pan, aim, hover, ignore }
    /// Either Shift key is held: the finger shows a pointer instead of inking.
    private var hoverKeyDown: Bool { NSEvent.modifierFlags.contains(.shift) }
    private var hoverPoint: CGPoint?
    private var mode: Mode = .idle
    private var trackedID: NSObjectProtocol?
    private var lastNorm = CGPoint.zero

    /// While captured, the system cursor is frozen and hidden so the trackpad only draws.
    private(set) var captured = false

    // MARK: Setup

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        if edit != nil { layoutField() }
        followPad()
    }

    // MARK: Cursor capture

    func setCapture(_ on: Bool) {
        guard on != captured, window != nil else { return }
        captured = on
        if on {
            warpCursorToCenter()
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
        } else {
            finishTouch()
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
        needsDisplay = true
    }

    /// Touch events go to the view under the cursor, so park it in the middle of the board.
    private func warpCursorToCenter() {
        guard let window, let primary = NSScreen.screens.first else { return }
        let inWindow = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primary.frame.height - onScreen.y))
    }

    override func mouseDown(with event: NSEvent) {
        if !captured {
            setCapture(true)
        } else {
            clickAtPointer()
        }
    }

    /// Control + click arrives as a right click on some setups.
    override func rightMouseDown(with event: NSEvent) {
        if captured { clickAtPointer() }
    }

    /// Pressing the trackpad with the hover pointer (Shift) or the target crosshair (Control)
    /// on a block opens that block for editing.
    private func clickAtPointer() {
        guard let point = hoverPoint ?? anchor, let block = block(at: point) else { return }
        if hoverPoint == nil {
            // The crosshair was only used to pick the block.
            anchor = nil
            anchorIsPreview = false
        }
        // The finger is still down: it must not ink, move the target or count as a tap.
        current = nil
        mode = .ignore
        hoverPoint = nil
        hoverStart = nil
        beginEdit(of: block)
    }

    // MARK: Touches

    override func touchesBegan(with event: NSEvent) { handleTouches(event) }
    override func touchesMoved(with event: NSEvent) { handleTouches(event) }
    override func touchesEnded(with event: NSEvent) { handleTouches(event) }
    override func touchesCancelled(with event: NSEvent) { handleTouches(event) }

    private func handleTouches(_ event: NSEvent) {
        guard captured else { return }
        let active = event.touches(matching: .touching, in: self)
        let commandDown = NSEvent.modifierFlags.contains(.command)
        let controlDown = NSEvent.modifierFlags.contains(.control)

        if let size = active.first?.deviceSize, size.width > 0, size.height > 0 {
            let aspect = size.width / size.height
            if abs(aspect - padAspect) > 0.001 {
                padAspect = aspect
                followPad()
            }
        }

        if active.isEmpty {
            finishTouch()
            return
        }

        // A second finger right after touch-down means a gesture, not writing.
        if active.count > 1, mode == .draw, (current?.points.count ?? 0) < 4 {
            current = nil
            mode = .ignore
            needsDisplay = true
            return
        }

        if let id = trackedID {
            guard let touch = active.first(where: { $0.identity.isEqual(id) }) else {
                // The tracked finger lifted while another is still down.
                commitCurrent()
                mode = .ignore
                return
            }
            touchMoved(touch, commandDown: commandDown, controlDown: controlDown)
        } else if mode == .idle, active.count == 1, let touch = active.first {
            trackedID = touch.identity
            let norm = touch.normalizedPosition
            lastNorm = norm
            if commandDown {
                mode = .pan
            } else if controlDown {
                mode = .aim
                if anchor == nil { anchor = defaultAnchor() }
            } else if hoverKeyDown {
                mode = .hover
                hoverPoint = worldPoint(norm)
                hoverStart = (Date(), norm)
                hoverTravel = 0
            } else {
                mode = .draw
                repositionForTouch(at: norm)
                current = Stroke(start: worldPoint(norm))
            }
            needsDisplay = true
        }
    }

    /// Where the crosshair starts: the end of the last stroke (like a text caret),
    /// or the middle of the zone on an empty board.
    private func defaultAnchor() -> CGPoint {
        strokes.last?.points.last ?? CGPoint(x: padRect.midX, y: padRect.midY)
    }

    /// Pressing Control shows the crosshair straight away; releasing it without
    /// moving the crosshair removes it again so nothing changes by accident.
    override func flagsChanged(with event: NSEvent) {
        guard captured else { return }
        if event.modifierFlags.contains(.control) {
            if anchor == nil {
                anchor = defaultAnchor()
                anchorIsPreview = true
                followPoint(anchor!)
            }
        } else if anchorIsPreview {
            anchor = nil
            anchorIsPreview = false
            followPad()
        }
        needsDisplay = true
    }

    /// Scrolls the board the minimum amount needed to keep a point on screen.
    private func followPoint(_ p: CGPoint) {
        camera.x = min(camera.x, p.x - cameraMargin)
        camera.x = max(camera.x, p.x + cameraMargin - bounds.width)
        camera.y = min(camera.y, p.y - cameraMargin)
        camera.y = max(camera.y, p.y + cameraMargin - bounds.height)
        needsDisplay = true
    }

    /// Moves the zone before a stroke starts: onto the precision anchor if one is set,
    /// otherwise further along the line when the previous ink reached the right end.
    private func repositionForTouch(at norm: CGPoint) {
        let r = padRect
        if let a = anchor {
            padOrigin = CGPoint(x: a.x - norm.x * r.width, y: a.y - (1 - norm.y) * r.height)
            anchor = nil
            anchorIsPreview = false
            followPad()
            return
        }
        // Only ink written since the last Enter counts: a new line never continues the old one.
        guard autoContinue, norm.x < continueLeftEdge, strokes.count > lineStart,
              let last = strokes.last,
              last.bounds.maxY > r.minY, last.bounds.minY < r.maxY,
              last.bounds.maxX >= r.minX + continueRightEdge * r.width,
              last.bounds.maxX <= r.maxX + 1 else { return }
        let inkMaxX = strokes[min(lineStart, strokes.count)...]
            .filter { $0.bounds.intersects(r) }
            .map { $0.bounds.maxX }.max() ?? last.bounds.maxX
        // The finger's current position becomes the spot just right of the ink.
        padOrigin.x = inkMaxX + 0.03 * r.width - norm.x * r.width
        followPad()
    }

    /// Height to move down for a new line: the height of the ink on the current line plus a gap.
    private func newLineStep() -> CGFloat {
        let r = padRect
        guard let used = currentLineBounds()?.height else { return r.height * lineStepFraction }
        return max(used + max(14, used * 0.2), r.height * 0.15)
    }

    /// The area used by the line being written: its ink in the zone's band, and blocks typed on it.
    private func currentLineBounds() -> CGRect? {
        let r = padRect
        let ink = strokes[min(lineStart, strokes.count)...]
            .filter { $0.bounds.maxY > r.minY && $0.bounds.minY < r.maxY }.map { $0.bounds }
        let blocks = typeset.filter { lineBlockIDs.contains($0.id) }.map { $0.bounds }
        let all = (ink + blocks).reduce(CGRect.null) { $0.union($1) }
        return all.isNull ? nil : all
    }

    private func touchMoved(_ touch: NSTouch, commandDown: Bool, controlDown: Bool) {
        let norm = touch.normalizedPosition
        switch mode {
        case .hover:
            if hoverKeyDown {
                hoverPoint = worldPoint(norm)
                if let start = hoverStart {
                    hoverTravel = max(hoverTravel, hypot(norm.x - start.norm.x, norm.y - start.norm.y))
                }
            } else {
                // Releasing Shift with the finger still down starts inking from the pointer.
                hoverPoint = nil
                mode = .draw
                current = Stroke(start: worldPoint(norm))
            }
            needsDisplay = true
        case .aim:
            if controlDown, let a = anchor {
                // Relative, like a normal trackpad: lift and re-touch to keep going further.
                let size = padRect.size
                let moved = CGPoint(x: a.x + (norm.x - lastNorm.x) * size.width,
                                    y: a.y - (norm.y - lastNorm.y) * size.height)
                anchor = moved
                anchorIsPreview = false
                followPoint(moved)
            } else {
                // The anchor stays where it was; wait for a fresh touch to write.
                mode = .ignore
            }
        case .draw:
            if commandDown {
                commitCurrent()
                mode = .pan
            } else if controlDown {
                commitCurrent()
                mode = .aim
                if anchor == nil { anchor = defaultAnchor() }
                needsDisplay = true
            } else if hoverKeyDown {
                commitCurrent()
                mode = .hover
                hoverPoint = worldPoint(norm)
                needsDisplay = true
            } else {
                let p = worldPoint(norm)
                if let last = current?.points.last, hypot(p.x - last.x, p.y - last.y) >= 0.5 {
                    current?.append(p)
                    needsDisplay = true
                }
            }
        case .pan:
            if commandDown {
                let size = padRect.size
                let dx = (norm.x - lastNorm.x) * size.width
                let dy = -(norm.y - lastNorm.y) * size.height
                if var editing = edit {
                    // A block is open: Command + finger moves that block instead of the zone.
                    editing.placement = editing.placement.moved(dx: dx, dy: dy)
                    edit = editing
                    if let index = typeset.firstIndex(where: { $0.id == editing.id }) {
                        typeset[index].move(dx: dx, dy: dy)
                        followPoint(CGPoint(x: typeset[index].bounds.minX, y: typeset[index].bounds.midY))
                    }
                    needsDisplay = true
                } else {
                    padOrigin.x += dx
                    padOrigin.y += dy
                    followPad()
                }
            } else {
                // Releasing Command mid-move must not start inking; wait for a fresh touch.
                mode = .ignore
            }
        case .idle, .ignore:
            break
        }
        lastNorm = norm
    }

    private func finishTouch() {
        commitCurrent()
        // A short Shift + tap on a block opens it for editing.
        if mode == .hover, captured, let point = hoverPoint, let start = hoverStart,
           Date().timeIntervalSince(start.time) < 0.4, hoverTravel < 0.04, let block = block(at: point) {
            beginEdit(of: block)
        }
        hoverStart = nil
        mode = .idle
        trackedID = nil
        if hoverPoint != nil {
            hoverPoint = nil
            needsDisplay = true
        }
    }


    private func commitCurrent() {
        guard let stroke = current else { return }
        strokes.append(stroke)
        undoStack.append(.stroke)
        current = nil
        needsDisplay = true
    }

    /// Trackpad positions are 0...1 with the origin at the bottom-left.
    private func worldPoint(_ norm: CGPoint) -> CGPoint {
        let r = padRect
        return CGPoint(x: r.minX + norm.x * r.width, y: r.minY + (1 - norm.y) * r.height)
    }

    // MARK: Camera

    /// Scrolls the board the minimum amount needed to keep the zone on screen.
    private func followPad() {
        let r = padRect
        let size = bounds.size
        if r.width + 2 * cameraMargin > size.width {
            camera.x = r.midX - size.width / 2
        } else {
            camera.x = min(camera.x, r.minX - cameraMargin)
            camera.x = max(camera.x, r.maxX + cameraMargin - size.width)
        }
        if r.height + 2 * cameraMargin > size.height {
            camera.y = r.midY - size.height / 2
        } else {
            camera.y = min(camera.y, r.minY - cameraMargin)
            camera.y = max(camera.y, r.maxY + cameraMargin - size.height)
        }
        needsDisplay = true
    }

    // MARK: Keys and menu actions

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if event.modifierFlags.contains(.shift) {
                // With the hover pointer on a block, Shift+Enter opens it instead.
                if let point = hoverPoint, let block = block(at: point) {
                    beginEdit(of: block)
                    return
                }
                if let previous = lineHistory.popLast() {
                    padOrigin = previous.origin
                    lineStart = min(previous.lineStart, strokes.count)
                } else {
                    padOrigin.y -= padRect.height * lineStepFraction
                    padOrigin.x = marginX
                }
                lineBlockIDs = []
                anchor = nil
                followPad()
            } else {
                newLine()
            }
        case 53: // Escape
            setCapture(!captured)
        case 51, 117: // Delete, forward delete: removes the block under the pointer or crosshair.
            if let point = hoverPoint ?? anchor, let block = block(at: point) {
                typeset.removeAll { $0.id == block.id }
                lineBlockIDs.removeAll { $0 == block.id }
                undoStack.append(.block(id: block.id, previous: block))
                needsDisplay = true
            }
        default:
            if startsTyping(event) {
                beginTyping(with: event)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func newLine() {
        lineHistory.append((padOrigin, lineStart))
        recognizeCurrentLine()
        padOrigin.y += newLineStep()
        padOrigin.x = marginX
        lineStart = strokes.count
        lineBlockIDs = []
        anchor = nil
        followPad()
    }

    // MARK: Typing and editing blocks

    private func block(at point: CGPoint) -> Typeset? {
        typeset.last { $0.bounds.insetBy(dx: -6, dy: -6).contains(point) }
    }

    /// Any key that produces text opens a new block; shortcuts and navigation keys do not.
    private func startsTyping(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.function) { return false }
        // Delete, forward delete, Tab, Space.
        return ![51, 117, 48, 49].contains(event.keyCode)
    }

    /// Typed text goes on the precision target if set, else after what is already on the
    /// line, else at the top-left of the zone.
    private func placementForTyping() -> Typeset.Placement {
        if let a = anchor { return .leftCentre(a) }
        if let line = currentLineBounds() {
            return .leftCentre(CGPoint(x: line.maxX + typedFontSize * 0.5, y: line.midY))
        }
        let r = padRect
        return .topLeft(CGPoint(x: r.minX + 0.03 * r.width, y: r.minY + 0.06 * r.height))
    }

    private func beginTyping(with event: NSEvent) {
        edit = Edit(id: Typeset.newID(), original: nil, fontSize: typedFontSize, placement: placementForTyping())
        anchor = nil
        anchorIsPreview = false
        openField(with: "")
        // Hand the keystroke that started it to the field, so dead keys and accents work.
        field.currentEditor()?.keyDown(with: event)
    }

    private func beginEdit(of block: Typeset) {
        if edit?.id == block.id { return }
        if !commitEdit() { cancelEdit() }
        edit = Edit(id: block.id, original: block, fontSize: block.fontSize, placement: block.placement)
        openField(with: block.source)
    }

    private func openField(with text: String) {
        field.stringValue = text
        field.textColor = .labelColor
        field.isHidden = false
        layoutField()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        needsDisplay = true
    }

    /// The field sits at the bottom, away from the parked cursor, so touches keep reaching the board.
    private func layoutField() {
        let width = min(760, max(200, bounds.width - 80))
        field.frame = CGRect(x: (bounds.width - width) / 2, y: bounds.height - 86, width: width, height: 26)
    }

    /// Live preview: the block on the board follows the field while it can be typeset.
    func controlTextDidChange(_ obj: Notification) {
        guard var editing = edit else { return }
        let source = field.stringValue
        if source.trimmingCharacters(in: .whitespaces).isEmpty {
            typeset.removeAll { $0.id == editing.id }
            editing.valid = true
        } else if let block = Typeset(source: source, fontSize: editing.fontSize, placement: editing.placement,
                                      color: inkColor, id: editing.id) {
            if let index = typeset.firstIndex(where: { $0.id == editing.id }) {
                typeset[index] = block
            } else {
                typeset.append(block)
            }
            editing.valid = true
        } else {
            // Keep showing the last version that rendered.
            editing.valid = false
        }
        field.textColor = editing.valid ? .labelColor : .systemRed
        edit = editing
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let typedNewBlock = edit?.original == nil && typeset.contains { $0.id == edit?.id }
            if commitEdit(), typedNewBlock { newLine() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEdit()
            return true
        default:
            return false
        }
    }

    /// Keeps what the field shows. Returns false, leaving the field open, if it cannot be typeset.
    @discardableResult
    private func commitEdit() -> Bool {
        guard let editing = edit else { return true }
        guard editing.valid else {
            NSSound.beep()
            return false
        }
        let result = typeset.first { $0.id == editing.id }
        if result?.source != editing.original?.source || result?.origin != editing.original?.origin {
            undoStack.append(.block(id: editing.id, previous: editing.original))
            if editing.original == nil { lineBlockIDs.append(editing.id) }
        }
        closeField()
        return true
    }

    private func cancelEdit() {
        guard let editing = edit else { return }
        typeset.removeAll { $0.id == editing.id }
        if let original = editing.original { typeset.append(original) }
        closeField()
    }

    private func closeField() {
        edit = nil
        window?.makeFirstResponder(self)
        field.isHidden = true
        needsDisplay = true
    }

    @objc func undoStroke(_ sender: Any?) {
        if edit != nil {
            // While typing, undo belongs to the text field.
            field.currentEditor()?.undoManager?.undo()
            return
        }
        guard let item = undoStack.popLast() else { return }
        switch item {
        case .block(let id, let previous):
            typeset.removeAll { $0.id == id }
            lineBlockIDs.removeAll { $0 == id }
            if let previous { typeset.append(previous) }
        case .stroke:
            if let last = strokes.popLast() { pendingStrokes.remove(last.id) }
        case .clear(let oldStrokes, let oldTypeset):
            strokes = oldStrokes
            typeset = oldTypeset
        case .recognized(let ink, let typesetID):
            typeset.removeAll { $0.id == typesetID }
            for (index, stroke) in ink {
                let at = min(index, strokes.count)
                strokes.insert(stroke, at: at)
                shiftLineStarts(from: at, by: 1)
            }
        }
        lineStart = min(lineStart, strokes.count)
        needsDisplay = true
    }

    @objc func toggleAutoContinue(_ sender: Any?) {
        autoContinue.toggle()
        (sender as? NSMenuItem)?.state = autoContinue ? .on : .off
    }

    @objc func clearBoard(_ sender: Any?) {
        if let editing = edit {
            // With a block open, the shortcut deletes that block rather than the whole board.
            typeset.removeAll { $0.id == editing.id }
            if let original = editing.original {
                lineBlockIDs.removeAll { $0 == editing.id }
                undoStack.append(.block(id: editing.id, previous: original))
            }
            closeField()
            return
        }
        guard !strokes.isEmpty || !typeset.isEmpty else { return }
        undoStack.append(.clear(strokes, typeset))
        strokes = []
        typeset = []
        pendingStrokes = []
        lineStart = 0
        lineBlockIDs = []
        needsDisplay = true
    }

    @objc func toggleRecognize(_ sender: Any?) {
        recognizeOnEnter.toggle()
        (sender as? NSMenuItem)?.state = recognizeOnEnter ? .on : .off
    }

    @objc func toggleAccurateModel(_ sender: Any?) {
        useAccurateModel.toggle()
        (sender as? NSMenuItem)?.state = useAccurateModel ? .on : .off
        warmUpRecognition()
    }

    @objc func toggleClaudeCode(_ sender: Any?) {
        useClaudeCode.toggle()
        (sender as? NSMenuItem)?.state = useClaudeCode ? .on : .off
        warnedAboutSetup = false
        if useClaudeCode { warmUpRecognition() } else { ClaudeCodeSession.shared.stop() }
    }

    /// Applies the choice made in the setup dialog.
    func setRecognition(enabled: Bool, viaClaudeCode: Bool) {
        recognizeOnEnter = enabled
        useClaudeCode = viaClaudeCode
        warnedAboutSetup = false
        if enabled, viaClaudeCode { warmUpRecognition() } else { ClaudeCodeSession.shared.stop() }
    }

    /// Starts the Claude Code process early so the first line is not slower than the rest.
    func warmUpRecognition() {
        if recognizeOnEnter, useClaudeCode { ClaudeCodeSession.shared.warmUp(model: model) }
    }

    // MARK: Recognition

    /// Sends the ink written since the last Enter; the answer replaces it whenever it arrives.
    private func recognizeCurrentLine() {
        guard recognizeOnEnter else { return }
        let line = strokes[min(lineStart, strokes.count)...].filter { !pendingStrokes.contains($0.id) }
        guard !line.isEmpty else { return }
        let key = useClaudeCode ? nil : Recognizer.apiKey()
        let problem: String? = useClaudeCode
            ? (ClaudeCodeSession.executable() == nil ? "the claude command was not found. Install Claude Code or switch to an API key in the Board menu." : nil)
            : (key == nil ? "no API key. Put one in ~/.config/trackpad-board/api_key, or switch to Claude Code in the Board menu." : nil)
        if let problem {
            if !warnedAboutSetup {
                warnedAboutSetup = true
                show(notice: "Recognition is off: \(problem)", seconds: 12)
            }
            return
        }
        guard let png = BoardView.renderPNG(of: line, strokeWidth: strokeWidth) else { return }
        let ids = Set(line.map { $0.id })
        pendingStrokes.formUnion(ids)
        pendingLines += 1
        needsDisplay = true
        let done: (Result<String, Recognizer.Failure>) -> Void = { [weak self] result in
            self?.finishRecognition(of: ids, result: result)
        }
        if let key {
            Recognizer.recognize(png: png, model: model, key: key, completion: done)
        } else {
            ClaudeCodeSession.shared.recognize(png: png, model: model, completion: done)
        }
    }

    private func finishRecognition(of ids: Set<Int>, result: Result<String, Recognizer.Failure>) {
        pendingLines -= 1
        pendingStrokes.subtract(ids)
        needsDisplay = true
        // The line was edited, undone or cleared while waiting: keep what is on the board.
        let ink = strokes.enumerated().filter { ids.contains($0.element.id) }
        guard ink.count == ids.count else { return }
        switch result {
        case .failure(let failure):
            show(notice: "Recognition failed: \(failure.message)", seconds: 8)
        case .success(let latex):
            let area = ink.map { $0.element.bounds }.reduce(CGRect.null) { $0.union($1) }
            guard let item = Typeset(latex: latex, replacing: area, color: inkColor) else {
                show(notice: "Could not typeset the answer: \(latex)", seconds: 8)
                return
            }
            for (index, _) in ink.reversed() {
                strokes.remove(at: index)
                shiftLineStarts(from: index + 1, by: -1)
            }
            typeset.append(item)
            undoStack.append(.recognized(ink: ink.map { (index: $0.offset, stroke: $0.element) },
                                         typesetID: item.id))
        }
    }

    /// Keeps the line bookkeeping pointing at the same strokes after an insert or removal.
    private func shiftLineStarts(from index: Int, by delta: Int) {
        if lineStart >= index { lineStart = max(0, lineStart + delta) }
        for i in lineHistory.indices where lineHistory[i].lineStart >= index {
            lineHistory[i].lineStart = max(0, lineHistory[i].lineStart + delta)
        }
    }

    private func show(notice text: String, seconds: Double) {
        notice = text
        noticeToken += 1
        let token = noticeToken
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.noticeToken == token else { return }
            self.notice = nil
            self.needsDisplay = true
        }
    }

    /// The ink colour resolved for the current light / dark appearance.
    private var inkColor: NSColor {
        var color = NSColor.black
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
        }
        return color
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let color = inkColor
        for i in typeset.indices { typeset[i].recolor(color) }
        needsDisplay = true
    }

    /// Black ink on white, cropped to the strokes and enlarged so small writing stays legible.
    static func renderPNG(of line: [Stroke], strokeWidth: CGFloat) -> Data? {
        let ink = line.map { $0.bounds }.reduce(CGRect.null) { $0.union($1) }
        guard !ink.isNull else { return nil }
        let area = ink.insetBy(dx: -24, dy: -24)
        var scale = min(max(260 / area.height, 1.5), 4)
        scale = min(scale, 1568 / area.width, 1568 / area.height)
        let width = Int((area.width * scale).rounded(.up)), height = Int((area.height * scale).rounded(.up))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Board coordinates grow downward, bitmap coordinates upward.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in line { ctx.addPath(stroke.path) }
        ctx.strokePath()
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    @objc func setMarginHere(_ sender: Any?) {
        marginX = padOrigin.x
        needsDisplay = true
    }

    @objc func growZone(_ sender: Any?) { resizeZone(by: 1.15) }
    @objc func shrinkZone(_ sender: Any?) { resizeZone(by: 1 / 1.15) }

    private func resizeZone(by factor: CGFloat) {
        padWidth = min(max(padWidth * factor, 150), 3000)
        followPad()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        ctx.saveGState()
        ctx.translateBy(x: -camera.x, y: -camera.y)

        // Left margin guide.
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: marginX, y: camera.y))
        ctx.addLine(to: CGPoint(x: marginX, y: camera.y + bounds.height))
        ctx.strokePath()

        // Ink.
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let visible = CGRect(origin: camera, size: bounds.size).insetBy(dx: -strokeWidth, dy: -strokeWidth)
        for stroke in strokes where !pendingStrokes.contains(stroke.id)
            && stroke.bounds.insetBy(dx: -2, dy: -2).intersects(visible) {
            ctx.addPath(stroke.path)
        }
        if let current { ctx.addPath(current.path) }
        ctx.strokePath()

        // Lines waiting for their recognition result are dimmed.
        if !pendingStrokes.isEmpty {
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.45).cgColor)
            for stroke in strokes where pendingStrokes.contains(stroke.id) { ctx.addPath(stroke.path) }
            ctx.strokePath()
        }

        // Typeset blocks.
        for item in typeset where item.bounds.intersects(visible) {
            item.image.draw(in: item.bounds, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
        }

        // The block under the hover pointer, and the one being edited.
        if edit == nil, let point = hoverPoint ?? anchor, let hovered = block(at: point) {
            ctx.addPath(CGPath(roundedRect: hovered.bounds.insetBy(dx: -6, dy: -6),
                               cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
        if let editing = edit {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            if let block = typeset.first(where: { $0.id == editing.id }) {
                ctx.addPath(CGPath(roundedRect: block.bounds.insetBy(dx: -6, dy: -6),
                                   cornerWidth: 5, cornerHeight: 5, transform: nil))
            } else {
                // Nothing typed yet: a caret where the block will appear.
                let top: CGPoint
                switch editing.placement {
                case .topLeft(let p): top = p
                case .leftCentre(let p): top = CGPoint(x: p.x, y: p.y - editing.fontSize / 2)
                }
                ctx.move(to: top)
                ctx.addLine(to: CGPoint(x: top.x, y: top.y + editing.fontSize))
            }
            ctx.strokePath()
        }

        // Trackpad zone outline.
        let accent = captured ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        let outline = CGPath(roundedRect: padRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(outline)
        ctx.setFillColor(accent.withAlphaComponent(0.04).cgColor)
        ctx.fillPath()
        ctx.addPath(outline)
        ctx.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.strokePath()

        // Precision anchor crosshair.
        if let a = anchor {
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: a.x - 14, y: a.y)); ctx.addLine(to: CGPoint(x: a.x - 3, y: a.y))
            ctx.move(to: CGPoint(x: a.x + 3, y: a.y)); ctx.addLine(to: CGPoint(x: a.x + 14, y: a.y))
            ctx.move(to: CGPoint(x: a.x, y: a.y - 14)); ctx.addLine(to: CGPoint(x: a.x, y: a.y - 3))
            ctx.move(to: CGPoint(x: a.x, y: a.y + 3)); ctx.addLine(to: CGPoint(x: a.x, y: a.y + 14))
            ctx.strokePath()
        }

        // Hover pointer.
        if let h = hoverPoint {
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: h.x - 2.5, y: h.y - 2.5, width: 5, height: 5))
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: h.x - 9, y: h.y - 9, width: 18, height: 18))
        }
        ctx.restoreGState()

        drawHint()
    }

    private func drawHint() {
        let text = edit != nil
            ? "Typing  ·  math goes between $…$  ·  ↩ keep  ·  esc cancel  ·  ⌘ + finger: move this block  ·  ⌘⌫ delete it"
            : captured
            ? "⌘ + finger: move zone  ·  ⌃ + finger: move target  ·  ⇧ + finger: hover  ·  ⇧ or ⌃ + click on a block: edit, ⌫: delete  ·  type: add text  ·  ↩ new line  ·  ⇧↩ previous line  ·  ⌘Z undo  ·  esc: release cursor"
            : "Click or press esc to capture the trackpad"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 8),
                  withAttributes: attrs)

        let status = notice ?? (pendingLines > 0 ? "Recognizing \(pendingLines) line\(pendingLines == 1 ? "" : "s")…" : nil)
        if let status {
            let statusSize = status.size(withAttributes: attrs)
            status.draw(at: CGPoint(x: (bounds.width - statusSize.width) / 2,
                                    y: bounds.height - size.height - statusSize.height - 14),
                        withAttributes: attrs)
        }
    }
}

/// Keeps the menu checkmarks in step with the settings, whoever changed them.
extension BoardView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleAutoContinue(_:)): item.state = autoContinue ? .on : .off
        case #selector(toggleRecognize(_:)): item.state = recognizeOnEnter ? .on : .off
        case #selector(toggleAccurateModel(_:)): item.state = useAccurateModel ? .on : .off
        case #selector(toggleClaudeCode(_:)): item.state = useClaudeCode ? .on : .off
        default: break
        }
        return true
    }
}
