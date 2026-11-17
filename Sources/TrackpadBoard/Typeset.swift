import AppKit
import SwiftMath

/// A recognized line, drawn as typeset math in place of the handwriting.
struct Typeset {
    private static var nextID = 0

    let id: Int
    let latex: String
    let fontSize: CGFloat
    /// Top-left corner on the board.
    let origin: CGPoint
    private(set) var image: NSImage

    var bounds: CGRect { CGRect(origin: origin, size: image.size) }

    /// Typesets `latex` over the area the handwriting used: same left edge, same vertical
    /// centre, and about the same height. Returns nil when the LaTeX cannot be rendered.
    init?(latex: String, replacing ink: CGRect, color: NSColor) {
        let probeSize: CGFloat = 20
        guard let probe = MathRenderer.image(latex: latex, fontSize: probeSize, color: color),
              probe.size.height > 0 else { return nil }
        let size = min(max(probeSize * ink.height / probe.size.height, 16), 40)
        guard let image = MathRenderer.image(latex: latex, fontSize: size, color: color) else { return nil }
        Typeset.nextID += 1
        id = Typeset.nextID
        self.latex = latex
        fontSize = size
        self.image = image
        origin = CGPoint(x: ink.minX, y: ink.midY - image.size.height / 2)
    }

    /// Re-renders in a new ink colour (light / dark mode switch).
    mutating func recolor(_ color: NSColor) {
        if let fresh = MathRenderer.image(latex: latex, fontSize: fontSize, color: color) { image = fresh }
    }
}

enum MathRenderer {
    /// Common commands the renderer does not know, mapped to ones it does.
    private static let substitutes = [
        ("\\operatorname*{", "\\mathrm{"), ("\\operatorname{", "\\mathrm{"),
        ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"),
        ("\\lvert", "|"), ("\\rvert", "|"), ("\\lVert", "\\|"), ("\\rVert", "\\|"),
    ]

    static func normalize(_ latex: String) -> String {
        substitutes.reduce(latex) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    static func image(latex: String, fontSize: CGFloat, color: NSColor) -> NSImage? {
        let renderer = MTMathImage(latex: normalize(latex), fontSize: fontSize, textColor: color,
                                   labelMode: .display, textAlignment: .left)
        let (error, image) = renderer.asImage()
        return error == nil ? image : nil
    }
}
