import AppKit

/// Turns a board into a LaTeX document: blocks become text and math in reading order, and
/// leftover ink becomes pictures included at their place in that order.
///
/// LaTeX flows text, so only the order survives: rows top to bottom, and left to right within
/// a row. Exact positions are what the PDF export is for.
enum LatexExport {
    struct Output {
        var tex: String
        /// Pictures to write next to the .tex file.
        var figures: [(name: String, pdf: Data)]
    }

    private enum Content {
        case block(source: String)
        case figure(strokes: [Stroke])
    }

    private struct Item {
        var bounds: CGRect
        var content: Content
    }

    /// Board points to LaTeX points: typed text is 24 on the board and 10 in the document.
    private static let scale: CGFloat = 10.0 / 24.0
    private static let textWidth: CGFloat = 345

    static func document(blocks: [(source: String, bounds: CGRect)], strokes: [Stroke],
                         strokeWidth: CGFloat, figurePrefix: String) -> Output {
        var items = blocks.map { Item(bounds: $0.bounds, content: .block(source: $0.source)) }
        items += figures(from: strokes).map { group in
            Item(bounds: group.map { $0.bounds }.reduce(CGRect.null) { $0.union($1) }, content: .figure(strokes: group))
        }

        var output = Output(tex: "", figures: [])
        var body: [String] = []
        for row in rows(of: items) {
            // A formula alone on its row is displayed; anything else is set inline, in order.
            if row.count == 1, case .block(let source) = row[0].content, let math = soleMath(in: source) {
                body.append("\\[\n  \(math)\n\\]")
                continue
            }
            let parts = row.map { item -> String in
                switch item.content {
                case .block(let source):
                    return inline(source)
                case .figure(let group):
                    let name = "\(figurePrefix)-fig\(output.figures.count + 1)"
                    output.figures.append((name, pdf(of: group, strokeWidth: strokeWidth)))
                    let width = item.bounds.width * scale
                    let size = width > textWidth ? "width=\\linewidth" : String(format: "width=%.0fpt", width)
                    return "\\includegraphics[\(size)]{\(name)}"
                }
            }
            body.append(parts.joined(separator: " \\quad\n"))
        }

        output.tex = """
        \\documentclass{article}
        \\usepackage[utf8]{inputenc}
        \\usepackage[T1]{fontenc}
        \\usepackage{amsmath,amssymb}
        \\usepackage{graphicx}
        \\setlength{\\parindent}{0pt}
        \\setlength{\\parskip}{0.8em}

        \\begin{document}

        \(body.joined(separator: "\n\n"))

        \\end{document}

        """
        return output
    }

    // MARK: Layout

    /// Ink that sits together is one picture: strokes are linked when they are close, with more
    /// tolerance sideways (gaps between words) than up and down (gaps between lines).
    private static func figures(from strokes: [Stroke]) -> [[Stroke]] {
        var group = Array(strokes.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while group[i] != i { i = group[i] }
            return i
        }
        let reach = strokes.map { $0.bounds.insetBy(dx: -30, dy: -6) }
        for i in strokes.indices {
            for j in strokes.indices where j > i && reach[i].intersects(reach[j]) {
                let (a, b) = (root(i), root(j))
                if a != b { group[b] = a }
            }
        }
        var byRoot: [Int: [Stroke]] = [:]
        for i in strokes.indices { byRoot[root(i), default: []].append(strokes[i]) }
        return Array(byRoot.values)
    }

    /// Items whose heights mostly overlap share a row.
    private static func rows(of items: [Item]) -> [[Item]] {
        var rows: [(band: ClosedRange<CGFloat>, items: [Item])] = []
        for item in items.sorted(by: { $0.bounds.midY < $1.bounds.midY }) {
            let b = item.bounds
            if let last = rows.indices.last {
                let band = rows[last].band
                let overlap = min(band.upperBound, b.maxY) - max(band.lowerBound, b.minY)
                if overlap > 0.5 * min(b.height, band.upperBound - band.lowerBound) {
                    rows[last].items.append(item)
                    rows[last].band = min(band.lowerBound, b.minY)...max(band.upperBound, b.maxY)
                    continue
                }
            }
            rows.append((b.minY...b.maxY, [item]))
        }
        return rows.map { $0.items.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    // MARK: Text

    /// The formula, when the block is nothing but one `$...$`.
    private static func soleMath(in source: String) -> String? {
        let parts = source.components(separatedBy: "$")
        guard parts.count == 3, parts[0].trimmingCharacters(in: .whitespaces).isEmpty,
              parts[2].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let math = parts[1].trimmingCharacters(in: .whitespaces)
        return math.isEmpty ? nil : math
    }

    /// The block's own notation is already LaTeX-like; only the plain text needs escaping.
    private static func inline(_ source: String) -> String {
        source.components(separatedBy: "$").enumerated().map { index, part in
            if index % 2 == 1 {
                let math = part.trimmingCharacters(in: .whitespaces)
                return math.isEmpty ? "" : "$\(math)$"
            }
            return escape(part)
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        let replacements: [Character: String] = [
            "\\": "\\textbackslash{}", "{": "\\{", "}": "\\}", "#": "\\#", "%": "\\%", "&": "\\&",
            "_": "\\_", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}",
        ]
        return text.map { replacements[$0] ?? String($0) }.joined()
    }

    // MARK: Pictures

    /// The strokes as a small vector PDF, cropped to them, on a transparent background.
    private static func pdf(of strokes: [Stroke], strokeWidth: CGFloat) -> Data {
        let area = strokes.map { $0.bounds }.reduce(CGRect.null) { $0.union($1) }
            .insetBy(dx: -strokeWidth, dy: -strokeWidth)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: area.size)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: area.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -area.minX, y: -area.minY)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes { ctx.addPath(stroke.path) }
        ctx.strokePath()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
