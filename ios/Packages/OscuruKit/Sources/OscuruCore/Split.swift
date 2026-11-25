import Foundation

/// Part of the frame as it is shown (after the crop), as fractions from its top-left corner.
public struct FrameRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let maxParts = 20

    /// The parts a script asks to split the photo into: a list of regions, or `{ columns, rows }`
    /// for equal parts in a grid, read across then down.
    public static func parts(_ value: JSONValue) throws -> [FrameRegion] {
        if let list = value.arrayValue {
            guard (1...maxParts).contains(list.count) else { throw StateError("split takes 1 to \(maxParts) parts, got \(list.count)") }
            return try list.enumerated().map { index, item in
                let path = "split[\(index)]"
                let input = try checkKeys(path, item, ["x", "y", "width", "height"])
                for key in ["x", "y", "width", "height"] where input[key] == nil {
                    throw StateError("\(path) needs x, y, width and height")
                }
                let region = FrameRegion(
                    x: try checkNumber("\(path).x", input["x"]!, (0, 1)), y: try checkNumber("\(path).y", input["y"]!, (0, 1)),
                    width: try checkNumber("\(path).width", input["width"]!, (0.02, 1)), height: try checkNumber("\(path).height", input["height"]!, (0.02, 1)))
                guard region.x + region.width <= 1.000001, region.y + region.height <= 1.000001 else {
                    throw StateError("\(path) leaves the frame: x + width and y + height must be at most 1")
                }
                return region
            }
        }
        guard value.objectValue != nil else {
            throw StateError("split takes a list of regions ({ x, y, width, height }) or { columns, rows }, got \(value.described)")
        }
        let input = try checkKeys("split", value, ["columns", "rows"])
        func count(_ key: String) throws -> Int {
            guard let value = input[key] else { return 1 }
            let number = try checkNumber("split.\(key)", value, (1, Double(maxParts)))
            guard number == number.rounded() else { throw StateError("split.\(key) must be a whole number, got \(formatNumber(number))") }
            return Int(number)
        }
        let columns = try count("columns")
        let rows = try count("rows")
        guard columns * rows >= 2, columns * rows <= maxParts else {
            throw StateError("split into a grid needs 2 to \(maxParts) parts, got \(columns) columns × \(rows) rows")
        }
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                FrameRegion(x: Double(column) / Double(columns), y: Double(row) / Double(rows), width: 1 / Double(columns), height: 1 / Double(rows))
            }
        }
    }
}

extension EditingState {
    /// The frame's width over its height as shown: the photo's (or collage's) own proportions, turned
    /// and cropped as these settings say.
    public func frameAspect(photoWidth: Int, photoHeight: Int) -> Double {
        let own = layout?.aspect ?? Double(photoWidth) / Double(max(1, photoHeight))
        let turned = crop.rotation % 180 == 0 ? own : 1 / own
        return turned * crop.width / crop.height
    }

    /// These settings for a new photo that is only `region` of this one: the crop narrowed to it, and
    /// local adjustments moved so they stay where they were on the picture. `frameAspect` is the
    /// frame's width over height (see `frameAspect(photoWidth:photoHeight:)`).
    public func part(_ region: FrameRegion, frameAspect: Double) throws -> EditingState {
        var part = self
        part.crop.x = crop.x + region.x * crop.width
        part.crop.y = crop.y + region.y * crop.height
        part.crop.width = region.width * crop.width
        part.crop.height = region.height * crop.height
        guard part.crop.width >= Specs.minCropSize - 1e-9, part.crop.height >= Specs.minCropSize - 1e-9 else {
            throw StateError(
                "a part \(formatNumber(region.width)) × \(formatNumber(region.height)) of the frame is smaller than the smallest crop (\(formatNumber(Specs.minCropSize)) of the photo on each side)"
            )
        }
        // Lengths measured on the long edge grow by how much shorter the part's long edge is.
        let longEdge = max(frameAspect, 1)
        let partLongEdge = max(frameAspect * region.width, region.height)
        let lengths = longEdge / partLongEdge
        part.local = local.map { adjustment in
            var moved = adjustment
            moved.mask = adjustment.mask.placed(in: region, lengths: lengths)
            return moved
        }
        return part
    }
}

extension Mask {
    /// The same mask on a part of the frame: positions taken into the part's coordinates, lengths on
    /// the long edge multiplied by `lengths`. A tap that falls outside the part is dropped.
    func placed(in region: FrameRegion, lengths: Double) -> Mask {
        var mask = self
        mask.area = area.placed(in: region, lengths: lengths)
        mask.add = add.map { $0.placed(in: region, lengths: lengths) }
        mask.subtract = subtract.map { $0.placed(in: region, lengths: lengths) }
        mask.intersect = intersect.map { $0.placed(in: region, lengths: lengths) }
        mask.grow = grow * lengths
        return mask
    }
}

extension MaskArea {
    func placed(in region: FrameRegion, lengths: Double) -> MaskArea {
        func point(_ p: [Double]) -> [Double] { [(p[0] - region.x) / region.width, (p[1] - region.y) / region.height] }
        func inside(_ p: [Double]) -> Bool { (0...1).contains(p[0]) && (0...1).contains(p[1]) }
        var area = self
        switch type {
        case "radial":
            let centre = point([x, y])
            area.x = centre[0]
            area.y = centre[1]
            area.width = width / region.width
            area.height = height / region.height
        case "linear":
            area.from = point(from)
            area.to = point(to)
        case "object":
            area.points = points.map(point).filter(inside)
            area.exclude = exclude.map(point).filter(inside)
        case "outline":
            area.points = points.map(point)
            area.feather = feather * lengths
        case "brush":
            area.strokes = strokes.map { $0.map(point) }
            area.size = size * lengths
            area.feather = feather * lengths
        default:
            break
        }
        return area
    }
}
