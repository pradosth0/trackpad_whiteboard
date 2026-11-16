import AppKit

/// One continuous finger contact, in board (world) coordinates.
struct Stroke {
    var points: [CGPoint]
    private(set) var path: CGPath
    private(set) var bounds: CGRect

    init(start: CGPoint) {
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

final class BoardView: NSView {
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
    private enum UndoItem { case stroke, clear([Stroke]) }
    private var undoStack: [UndoItem] = []

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
    /// Space is held: the finger shows a pointer instead of inking.
    private var spaceDown = false
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
            spaceDown = false
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
        if !captured { setCapture(true) }
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
            } else if spaceDown {
                mode = .hover
                hoverPoint = worldPoint(norm)
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
        let ink = strokes[min(lineStart, strokes.count)...]
            .filter { $0.bounds.maxY > r.minY && $0.bounds.minY < r.maxY }
        guard let top = ink.map({ $0.bounds.minY }).min(),
              let bottom = ink.map({ $0.bounds.maxY }).max() else {
            return r.height * lineStepFraction
        }
        let used = bottom - top
        return max(used + max(14, used * 0.2), r.height * 0.15)
    }

    private func touchMoved(_ touch: NSTouch, commandDown: Bool, controlDown: Bool) {
        let norm = touch.normalizedPosition
        switch mode {
        case .hover:
            if spaceDown {
                hoverPoint = worldPoint(norm)
            } else {
                // Releasing Space with the finger still down starts inking from the pointer.
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
            } else if spaceDown {
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
                padOrigin.x += (norm.x - lastNorm.x) * size.width
                padOrigin.y -= (norm.y - lastNorm.y) * size.height
                followPad()
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
        mode = .idle
        trackedID = nil
        if hoverPoint != nil {
            hoverPoint = nil
            needsDisplay = true
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) }
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
                if let previous = lineHistory.popLast() {
                    padOrigin = previous.origin
                    lineStart = min(previous.lineStart, strokes.count)
                } else {
                    padOrigin.y -= padRect.height * lineStepFraction
                    padOrigin.x = marginX
                }
            } else {
                lineHistory.append((padOrigin, lineStart))
                padOrigin.y += newLineStep()
                padOrigin.x = marginX
                lineStart = strokes.count
            }
            anchor = nil
            followPad()
        case 49: // Space: hover while held
            spaceDown = captured
        case 53: // Escape
            setCapture(!captured)
        default:
            super.keyDown(with: event)
        }
    }

    @objc func undoStroke(_ sender: Any?) {
        guard let item = undoStack.popLast() else { return }
        switch item {
        case .stroke: if !strokes.isEmpty { strokes.removeLast() }
        case .clear(let old): strokes = old
        }
        lineStart = min(lineStart, strokes.count)
        needsDisplay = true
    }

    @objc func toggleAutoContinue(_ sender: Any?) {
        autoContinue.toggle()
        (sender as? NSMenuItem)?.state = autoContinue ? .on : .off
    }

    @objc func clearBoard(_ sender: Any?) {
        guard !strokes.isEmpty else { return }
        undoStack.append(.clear(strokes))
        strokes = []
        lineStart = 0
        needsDisplay = true
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
        for stroke in strokes where stroke.path.boundingBoxOfPath.insetBy(dx: -2, dy: -2).intersects(visible) {
            ctx.addPath(stroke.path)
        }
        if let current { ctx.addPath(current.path) }
        ctx.strokePath()

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
        let text = captured
            ? "Trackpad captured  ·  ⌘ + finger: move zone  ·  ⌃ + finger: move next-stroke target  ·  space + finger: hover  ·  ↩ new line  ·  ⇧↩ previous line  ·  ⌘Z undo  ·  esc: release cursor"
            : "Click or press esc to capture the trackpad"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 8),
                  withAttributes: attrs)
    }
}
