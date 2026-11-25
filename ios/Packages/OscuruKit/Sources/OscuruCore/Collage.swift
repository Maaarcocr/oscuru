import Foundation

/// How a collage's pieces sit on its canvas: the canvas's shape, the space between pieces and its
/// colour, and one cell per piece shown. Part of the editing state, so the assistant changes it like
/// any other setting and every version keeps its own.
public struct CollageLayout: Codable, Equatable, Sendable {
    /// One piece in a rectangle of the canvas, cropped to fill it.
    public struct Cell: Codable, Equatable, Sendable {
        /// Which piece, as an index into the collage's pieces.
        public var piece: Int
        /// The rectangle, as fractions of the canvas from its top-left corner.
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// The point of the piece ([x, y], fractions of it from its top-left) kept in view when it
        /// is cropped to fill the cell.
        public var focus: [Double] = [0.5, 0.5]
        /// 1 fills the cell; more crops in further.
        public var zoom: Double = 1

        public init(piece: Int, x: Double, y: Double, width: Double, height: Double) {
            self.piece = piece
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var json: JSONValue {
            [
                "piece": .number(Double(piece)), "x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height),
                "focus": .array(focus.map { .number($0) }), "zoom": .number(zoom),
            ]
        }

        /// The part of a piece `pieceWidth` by `pieceHeight` shown in a cell `cellWidth` by
        /// `cellHeight` (any units), from the piece's top-left corner: the piece scaled to cover the
        /// cell, `zoom` times more, and moved so `focus` is as near the middle as it can be.
        public func window(pieceWidth: Double, pieceHeight: Double, cellWidth: Double, cellHeight: Double) -> (x: Double, y: Double, width: Double, height: Double) {
            let scale = max(cellWidth / pieceWidth, cellHeight / pieceHeight) * max(1, zoom)
            let width = min(pieceWidth, cellWidth / scale)
            let height = min(pieceHeight, cellHeight / scale)
            let x = min(pieceWidth - width, max(0, focus[0] * pieceWidth - width / 2))
            let y = min(pieceHeight - height, max(0, focus[1] * pieceHeight - height / 2))
            return (x, y, width, height)
        }
    }

    /// Width over height.
    public var aspect: Double
    /// Space between the pieces and around them, as a fraction of the canvas's long edge.
    public var gap: Double
    /// The colour around the pieces, "#RRGGBB".
    public var background: String
    /// Drawn in order: a later cell covers an earlier one where they overlap.
    public var cells: [Cell]

    public init(aspect: Double, gap: Double = CollageLayout.defaultGap, background: String = "#FFFFFF", cells: [Cell]) {
        self.aspect = aspect
        self.gap = gap
        self.background = background
        self.cells = cells
    }

    public static let maxPieces = 12
    public static let maxCells = 24
    public static let defaultGap = 0.012
    /// The long edge of a collage at full size, in pixels.
    public static let longEdge = 4096.0

    public var json: JSONValue {
        ["aspect": .number(aspect), "gap": .number(gap), "background": .string(background), "cells": .array(cells.map(\.json))]
    }

    /// The canvas at full size, in whole pixels.
    public var canvasSize: (width: Int, height: Int) {
        let long = CollageLayout.longEdge
        return aspect >= 1 ? (Int(long), Int((long / aspect).rounded())) : (Int((long * aspect).rounded()), Int(long))
    }

    /// The background as red, green and blue from 0 to 1 (sRGB).
    public var backgroundColor: [Double] {
        CollageLayout.color(background) ?? [1, 1, 1]
    }

    /// Where each cell lands on a canvas `width` by `height` (any units), from its top-left corner,
    /// after the gap: the same space between neighbouring pieces as around the edge.
    public func frames(width: Double, height: Double) -> [(cell: Cell, x: Double, y: Double, width: Double, height: Double)] {
        let space = gap * max(width, height)
        let innerWidth = max(1, width - space)
        let innerHeight = max(1, height - space)
        // The pieces sit in the canvas less half a gap all round, each less half a gap all round.
        return cells.map { cell in
            (cell, space + cell.x * innerWidth, space + cell.y * innerHeight, max(1, cell.width * innerWidth - space), max(1, cell.height * innerHeight - space))
        }
    }

    /// A starting arrangement for pieces of these proportions (width over height), with little cropped:
    /// one alone, two side by side (or stacked when wide), three as one large and two small, more in a grid.
    public static func automatic(aspects: [Double]) -> CollageLayout {
        let count = aspects.count
        let average = aspects.isEmpty ? 1 : aspects.reduce(0, +) / Double(count)
        let wide = average >= 1.1
        func clamped(_ aspect: Double) -> Double { min(2, max(0.5, aspect)) }
        switch count {
        case 0:
            return CollageLayout(aspect: 1, cells: [])
        case 1:
            return CollageLayout(aspect: min(4, max(0.25, aspects[0])), cells: [Cell(piece: 0, x: 0, y: 0, width: 1, height: 1)])
        case 2:
            if wide {
                return CollageLayout(
                    aspect: clamped(average / 2), cells: [Cell(piece: 0, x: 0, y: 0, width: 1, height: 0.5), Cell(piece: 1, x: 0, y: 0.5, width: 1, height: 0.5)])
            }
            return CollageLayout(
                aspect: clamped(average * 2), cells: [Cell(piece: 0, x: 0, y: 0, width: 0.5, height: 1), Cell(piece: 1, x: 0.5, y: 0, width: 0.5, height: 1)])
        case 3:
            if wide {
                return CollageLayout(
                    aspect: clamped(average * 0.9),
                    cells: [
                        Cell(piece: 0, x: 0, y: 0, width: 1, height: 0.6), Cell(piece: 1, x: 0, y: 0.6, width: 0.5, height: 0.4),
                        Cell(piece: 2, x: 0.5, y: 0.6, width: 0.5, height: 0.4),
                    ])
            }
            return CollageLayout(
                aspect: clamped(average * 1.6),
                cells: [
                    Cell(piece: 0, x: 0, y: 0, width: 0.6, height: 1), Cell(piece: 1, x: 0.6, y: 0, width: 0.4, height: 0.5),
                    Cell(piece: 2, x: 0.6, y: 0.5, width: 0.4, height: 0.5),
                ])
        default:
            let columns = Int(Double(count).squareRoot().rounded(.up))
            let rows = (count + columns - 1) / columns
            var cells: [Cell] = []
            for row in 0..<rows {
                let first = row * columns
                let inRow = min(columns, count - first)
                // A short last row is spread across the whole width, so there is no hole.
                for column in 0..<inRow {
                    cells.append(
                        Cell(
                            piece: first + column, x: Double(column) / Double(inRow), y: Double(row) / Double(rows), width: 1 / Double(inRow),
                            height: 1 / Double(rows)))
                }
            }
            return CollageLayout(aspect: clamped(average * Double(columns) / Double(rows)), cells: cells)
        }
    }

    /// "#RRGGBB" as red, green and blue from 0 to 1; nil when it is not one.
    static func color(_ text: String) -> [Double]? {
        let hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return [Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255]
    }

    /// Changes the layout from a script: values given replace theirs; `cells`, when given, replaces
    /// all of them. `pieces` is how many pieces the collage has.
    mutating func set(_ value: JSONValue, pieces: Int) throws {
        let input = try checkKeys("layout", value, ["aspect", "gap", "background", "cells"])
        var next = self
        if let value = input["aspect"] { next.aspect = try checkNumber("layout.aspect", value, (0.25, 4)) }
        if let value = input["gap"] { next.gap = try checkNumber("layout.gap", value, (0, 0.1)) }
        if let value = input["background"] {
            guard let text = value.stringValue, CollageLayout.color(text) != nil else {
                throw StateError("layout.background must be a colour as \"#RRGGBB\", got \(value.described)")
            }
            next.background = text.hasPrefix("#") ? text.uppercased() : "#" + text.uppercased()
        }
        if let value = input["cells"] {
            guard let list = value.arrayValue, (1...CollageLayout.maxCells).contains(list.count) else {
                throw StateError("layout.cells must be a list of 1 to \(CollageLayout.maxCells) cells, got \(value.described)")
            }
            next.cells = try list.enumerated().map { try CollageLayout.cell("layout.cells[\($0.offset)]", $0.element, pieces: pieces) }
        }
        self = next
    }

    static func cell(_ path: String, _ value: JSONValue, pieces: Int) throws -> Cell {
        let input = try checkKeys(path, value, ["piece", "x", "y", "width", "height", "focus", "zoom"])
        for key in ["piece", "x", "y", "width", "height"] where input[key] == nil {
            throw StateError("\(path) needs piece, x, y, width and height")
        }
        let piece = try checkNumber("\(path).piece", input["piece"]!, (0, Double(max(0, pieces - 1))))
        guard piece == piece.rounded() else { throw StateError("\(path).piece must be a whole number, got \(formatNumber(piece))") }
        var cell = Cell(
            piece: Int(piece), x: try checkNumber("\(path).x", input["x"]!, (0, 0.98)), y: try checkNumber("\(path).y", input["y"]!, (0, 0.98)),
            width: try checkNumber("\(path).width", input["width"]!, (0.02, 1)), height: try checkNumber("\(path).height", input["height"]!, (0.02, 1)))
        guard cell.x + cell.width <= 1.000001, cell.y + cell.height <= 1.000001 else {
            throw StateError("\(path) leaves the canvas: x + width and y + height must be at most 1")
        }
        if let value = input["focus"] {
            guard let pair = value.arrayValue, pair.count == 2 else { throw StateError("\(path).focus must be an [x, y] point, got \(value.described)") }
            cell.focus = [try checkNumber("\(path).focus[0]", pair[0], (0, 1)), try checkNumber("\(path).focus[1]", pair[1], (0, 1))]
        }
        if let value = input["zoom"] { cell.zoom = try checkNumber("\(path).zoom", value, (1, 5)) }
        return cell
    }
}

/// What a collage is made of: its pieces (developed copies of the photos it was made from, kept
/// beside this file) and the arrangement it started with. Saved as the collage's original file.
public struct CollageManifest: Codable, Equatable, Sendable {
    public struct Piece: Codable, Equatable, Sendable {
        /// Relative to the folder the manifest is in.
        public var file: String
        /// The photo it was made from.
        public var name: String
        public var width: Int
        public var height: Int

        public init(file: String, name: String, width: Int, height: Int) {
            self.file = file
            self.name = name
            self.width = width
            self.height = height
        }
    }

    public var pieces: [Piece]
    public var layout: CollageLayout

    /// Pieces arranged as `CollageLayout.automatic` would.
    public init(pieces: [Piece]) {
        self.pieces = pieces
        layout = CollageLayout.automatic(aspects: pieces.map { Double($0.width) / Double(max(1, $0.height)) })
    }

    public static let fileExtension = "collage"
}

extension EditingState {
    /// A collage's layout; a photo that is not a collage has none.
    public func collageLayout() throws -> CollageLayout {
        guard let layout else {
            throw StateError(
                "this photo is not a collage, so it has no layout. A collage is made in the library: the person selects photos and taps Combine.")
        }
        return layout
    }

    /// Changes a collage's layout.
    public mutating func setLayout(_ value: JSONValue, pieces: Int) throws {
        var next = try collageLayout()
        try next.set(value, pieces: pieces)
        layout = next
    }
}
