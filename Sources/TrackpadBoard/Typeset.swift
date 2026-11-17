import AppKit
import SwiftMath

/// A block of typeset text and math on the board: a recognized line or something typed.
struct Typeset {
    /// How the block is pinned to the board when its size changes.
    enum Placement {
        /// Left edge and vertical centre stay put (blocks that replaced handwriting).
        case leftCentre(CGPoint)
        /// Top-left corner stays put.
        case topLeft(CGPoint)

        func moved(dx: CGFloat, dy: CGFloat) -> Placement {
            switch self {
            case .leftCentre(let p): return .leftCentre(CGPoint(x: p.x + dx, y: p.y + dy))
            case .topLeft(let p): return .topLeft(CGPoint(x: p.x + dx, y: p.y + dy))
            }
        }
    }

    private static var nextID = 0
    static func newID() -> Int {
        nextID += 1
        return nextID
    }

    let id: Int
    /// What the user edits: plain text with math between `$...$`.
    let source: String
    /// What is rendered: math-mode LaTeX, with words inside `\text{...}`.
    let latex: String
    let fontSize: CGFloat
    private(set) var placement: Placement
    private(set) var image: NSImage

    /// Top-left corner on the board.
    var origin: CGPoint {
        switch placement {
        case .topLeft(let p): return p
        case .leftCentre(let p): return CGPoint(x: p.x, y: p.y - image.size.height / 2)
        }
    }
    var bounds: CGRect { CGRect(origin: origin, size: image.size) }

    /// Typesets recognized `latex` over the area the handwriting used: same left edge, same
    /// vertical centre, and about the same height. Returns nil when it cannot be rendered.
    init?(latex: String, replacing ink: CGRect, color: NSColor) {
        let probeSize: CGFloat = 20
        guard let probe = MathRenderer.image(latex: latex, fontSize: probeSize, color: color),
              probe.size.height > 0 else { return nil }
        let size = min(max(probeSize * ink.height / probe.size.height, 16), 40)
        guard let image = MathRenderer.image(latex: latex, fontSize: size, color: color) else { return nil }
        id = Typeset.newID()
        source = Markup.source(fromLatex: latex)
        self.latex = latex
        fontSize = size
        self.image = image
        placement = .leftCentre(CGPoint(x: ink.minX, y: ink.midY))
    }

    /// Typesets typed `source`. Returns nil when it cannot be rendered (for example mid-typing).
    init?(source: String, fontSize: CGFloat, placement: Placement, color: NSColor, id: Int) {
        let latex = Markup.latex(fromSource: source)
        guard !latex.isEmpty,
              let image = MathRenderer.image(latex: latex, fontSize: fontSize, color: color) else { return nil }
        self.id = id
        self.source = source
        self.latex = latex
        self.fontSize = fontSize
        self.placement = placement
        self.image = image
    }

    mutating func move(dx: CGFloat, dy: CGFloat) {
        placement = placement.moved(dx: dx, dy: dy)
    }

    /// Restores a saved block from both of its forms.
    init?(source: String, latex: String, fontSize: CGFloat, placement: Placement, color: NSColor) {
        guard let image = MathRenderer.image(latex: latex, fontSize: fontSize, color: color) else { return nil }
        id = Typeset.newID()
        self.source = source
        self.latex = latex
        self.fontSize = fontSize
        self.placement = placement
        self.image = image
    }

    /// Re-renders in a new ink colour (light / dark mode switch).
    mutating func recolor(_ color: NSColor) {
        if let fresh = MathRenderer.image(latex: latex, fontSize: fontSize, color: color) { image = fresh }
    }
}

/// Converts between the editable form (text with `$math$`) and math-mode LaTeX.
enum Markup {
    static func latex(fromSource source: String) -> String {
        var out = ""
        for (i, part) in source.components(separatedBy: "$").enumerated() {
            if i % 2 == 1 {
                out += part.trimmingCharacters(in: .whitespaces)
            } else if !part.isEmpty {
                // Inside \text these would be read as LaTeX (or cannot be rendered): drop or escape them.
                var plain = part.filter { !"{}\\&^~".contains($0) }
                for special in ["_", "%", "#"] {
                    plain = plain.replacingOccurrences(of: special, with: "\\" + special)
                }
                if !plain.isEmpty { out += "\\text{\(plain)}" }
            }
        }
        return out
    }

    /// Top-level `\text{...}` groups become plain text, everything else becomes `$...$`.
    static func source(fromLatex latex: String) -> String {
        var out = "", math = ""
        func flushMath() {
            let trimmed = math.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out += "$\(trimmed)$" }
            math = ""
        }
        var rest = Substring(latex)
        while let start = rest.range(of: "\\text{") {
            math += rest[..<start.lowerBound]
            var depth = 1
            var index = start.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "{" { depth += 1 } else if rest[index] == "}" { depth -= 1 }
                if depth > 0 { index = rest.index(after: index) }
            }
            guard depth == 0 else {
                // Unbalanced braces: leave the remainder as math.
                math += rest[start.lowerBound...]
                rest = ""
                break
            }
            let text = rest[start.upperBound..<index]
            // \text nested inside other braces (a subscript, a fraction) stays math.
            let openBraces = math.filter { $0 == "{" }.count - math.filter { $0 == "}" }.count
            if openBraces == 0 {
                flushMath()
                out += ["_", "%", "#"].reduce(String(text)) {
                    $0.replacingOccurrences(of: "\\" + $1, with: $1)
                }
            } else {
                math += "\\text{\(text)}"
            }
            rest = rest[rest.index(after: index)...]
        }
        math += rest
        flushMath()
        return out
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
