import Foundation

/// What a saved board (`.tboard`) contains: everything needed to reopen it exactly as it was.
/// The undo history and recognitions still in flight are not saved.
struct BoardFile: Codable, Equatable {
    static let fileExtension = "tboard"
    static let currentVersion = 1

    struct Point: Codable, Equatable {
        var x: Double
        var y: Double
    }

    struct Block: Codable, Equatable {
        /// Editable form: text with math between `$...$`.
        var source: String
        /// Rendered form: math-mode LaTeX.
        var latex: String
        var fontSize: Double
        /// "leftCentre" or "topLeft": which point of the block `position` pins.
        var anchor: String
        var position: Point
    }

    struct Line: Codable, Equatable {
        var zoneOrigin: Point
        var firstStroke: Int
    }

    var version = BoardFile.currentVersion
    /// One entry per stroke: its points flattened as x0, y0, x1, y1, …
    var strokes: [[Double]] = []
    var blocks: [Block] = []

    var zoneOrigin = Point(x: 0, y: 0)
    var zoneWidth = 560.0
    var zoneAspect = 1.6
    var marginX = 0.0
    var camera = Point(x: -40, y: -40)

    /// Line bookkeeping, so Enter and Shift+Enter continue where they left off.
    var lineFirstStroke = 0
    var lineBlocks: [Int] = []
    var previousLines: [Line] = []

    /// The autosaved state: the board as it was, which file it belongs to, and whether it
    /// had changes that file does not have.
    struct Recovery: Codable {
        var board: BoardFile
        var documentPath: String?
        var hasUnsavedChanges: Bool
    }

    struct UnsupportedVersion: LocalizedError {
        let version: Int
        var errorDescription: String? {
            "This board was saved by a newer version of Trackpad Board (file format \(version))."
        }
    }

    static func read(from url: URL) throws -> BoardFile {
        let file = try JSONDecoder().decode(BoardFile.self, from: Data(contentsOf: url))
        guard file.version <= currentVersion else { throw UnsupportedVersion(version: file.version) }
        return file
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
