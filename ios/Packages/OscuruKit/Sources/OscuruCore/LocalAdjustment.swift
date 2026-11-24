import Foundation

/// Where a mask starts from: a shape on the frame, something found in the photo, an outline or
/// brush strokes drawn by hand, or everything. Positions are fractions of the frame as it is shown
/// (after the crop), from its top-left corner.
public struct MaskArea: Codable, Equatable, Sendable {
    /// One of `Specs.maskAreas`.
    public var type: String
    /// Radial: the centre, the ellipse's full width and height (fractions of the frame's width and
    /// height), its turn in degrees clockwise, and how soft its edge is (0 hard, 1 soft from the centre).
    public var x = 0.5
    public var y = 0.5
    public var width = 0.5
    public var height = 0.5
    public var angle = 0.0
    /// Radial: 0 to 1 of the ellipse. Outline and brush: the soft edge's width as a fraction of the
    /// frame's long edge.
    public var feather = 0.5
    /// Linear: full strength at `from`, fading to nothing at `to`; each an [x, y] point.
    public var from = [0.5, 0.0]
    public var to = [0.5, 0.5]
    /// Object: [x, y] points on the thing to select. Outline: the corners of the shape, in order.
    public var points: [[Double]] = []
    /// Object: [x, y] points on things that are not part of it.
    public var exclude: [[Double]] = []
    /// Brush: strokes, each a list of [x, y] points the brush passes through (one point is a dab).
    public var strokes: [[[Double]]] = []
    /// Brush: its diameter as a fraction of the frame's long edge.
    public var size = 0.03

    public init(type: String) {
        self.type = type
    }

    public var json: JSONValue {
        func points(_ list: [[Double]]) -> JSONValue { .array(list.map { .array($0.map { .number($0) }) }) }
        switch type {
        case "radial":
            return [
                "type": "radial", "x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height), "angle": .number(angle),
                "feather": .number(feather),
            ]
        case "linear":
            return ["type": "linear", "from": .array(from.map { .number($0) }), "to": .array(to.map { .number($0) })]
        case "object":
            return ["type": "object", "points": points(self.points), "exclude": points(exclude)]
        case "outline":
            return ["type": "outline", "points": points(self.points), "feather": .number(feather)]
        case "brush":
            return ["type": "brush", "strokes": .array(strokes.map(points)), "size": .number(size), "feather": .number(feather)]
        default:
            return ["type": .string(type)]
        }
    }

    private enum CodingKeys: String, CodingKey { case type, x, y, width, height, angle, feather, from, to, points, exclude, strokes, size }

    // Areas saved before outlines, brushes and objects existed have none of their fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? x
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? y
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? width
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? height
        angle = try container.decodeIfPresent(Double.self, forKey: .angle) ?? angle
        feather = try container.decodeIfPresent(Double.self, forKey: .feather) ?? feather
        from = try container.decodeIfPresent([Double].self, forKey: .from) ?? from
        to = try container.decodeIfPresent([Double].self, forKey: .to) ?? to
        points = try container.decodeIfPresent([[Double]].self, forKey: .points) ?? []
        exclude = try container.decodeIfPresent([[Double]].self, forKey: .exclude) ?? []
        strokes = try container.decodeIfPresent([[[Double]]].self, forKey: .strokes) ?? []
        size = try container.decodeIfPresent(Double.self, forKey: .size) ?? size
    }
}

/// A band of values from 0 to 1 that a mask keeps, with soft edges `feather` wide: tones by display
/// luminance, or distances from nearest (0) to farthest (1).
public struct ValueRange: Codable, Equatable, Sendable {
    public var from: Double
    public var to: Double
    public var feather: Double

    public init(from: Double, to: Double, feather: Double) {
        self.from = from
        self.to = to
        self.feather = feather
    }

    public var json: JSONValue { ["from": .number(from), "to": .number(to), "feather": .number(feather)] }

    /// How much a value belongs to the band, 0 to 1. A band from 0 keeps 0 fully, one to 1 keeps 1.
    public func weight(_ value: Double) -> Double {
        let f = Swift.max(feather, 0.001)
        var weight = 1.0
        if from > 0 { weight *= ColorPipeline.smoothstep(from - f, from + f, value) }
        if to < 1 { weight *= 1 - ColorPipeline.smoothstep(to - f, to + f, value) }
        return weight
    }

    /// Checks a band from a script or a saved document.
    static func parse(_ path: String, _ value: JSONValue) throws -> ValueRange {
        let range = try checkKeys(path, value, ["from", "to", "feather"])
        guard let fromValue = range["from"], let toValue = range["to"] else { throw StateError("\(path) needs from and to") }
        let from = try checkNumber("\(path).from", fromValue, (0, 1))
        let to = try checkNumber("\(path).to", toValue, (0, 1))
        guard to - from >= 0.02 else { throw StateError("\(path).to must be above from (by at least 0.02), got from \(formatNumber(from)), to \(formatNumber(to))") }
        let feather = try range["feather"].map { try checkNumber("\(path).feather", $0, (0, 0.5)) } ?? 0.1
        return ValueRange(from: from, to: to, feather: feather)
    }
}

/// Which colours a mask keeps: hues within `range` degrees around `hue`, fading at the edges.
public struct HueRange: Codable, Equatable, Sendable {
    public var hue: Double
    public var range: Double

    public var json: JSONValue { ["hue": .number(hue), "range": .number(range)] }
}

/// Where a local adjustment applies: one or more areas joined together, with others cut out or
/// required, optionally turned inside out, narrowed to tones, colours and distances, grown or shrunk,
/// and snapped to the edges in the photo. In that order.
public struct Mask: Codable, Equatable, Sendable {
    public var area: MaskArea
    /// More areas joined with `area`: where they overlap the mask is as strong as the strongest, never stronger.
    public var add: [MaskArea] = []
    /// Areas cut out of it.
    public var subtract: [MaskArea] = []
    /// Areas it must also be in: what lies outside any of them is dropped.
    public var intersect: [MaskArea] = []
    public var invert = false
    public var luminance: ValueRange?
    public var color: HueRange?
    /// How far away, from the nearest part of the photo (0) to the farthest (1), as the phone estimates it.
    public var depth: ValueRange?
    /// Which picture tone and colour ranges are measured on: "current" (the photo as it is before
    /// this adjustment) or "original" (as developed, before tone and colour: before a style tinted it).
    public var measure = "current"
    /// Grows (above 0) or shrinks (below 0) the mask's edge, as a fraction of the frame's long edge.
    public var grow = 0.0
    /// How strongly the edge is snapped to edges in the photo, 0 (not at all) to 1.
    public var refine = 0.0

    public init(area: MaskArea) {
        self.area = area
    }

    /// Every area joined into the mask.
    public var areas: [MaskArea] { [area] + add }

    public var json: JSONValue {
        var members: [String: JSONValue] = [
            "area": add.isEmpty ? area.json : .array(areas.map(\.json)), "invert": .bool(invert), "measure": .string(measure),
            "grow": .number(grow), "refine": .number(refine),
        ]
        if !subtract.isEmpty { members["subtract"] = .array(subtract.map(\.json)) }
        if !intersect.isEmpty { members["intersect"] = .array(intersect.map(\.json)) }
        if let luminance { members["luminance"] = luminance.json }
        if let color { members["color"] = color.json }
        if let depth { members["depth"] = depth.json }
        return .object(members)
    }

    private enum CodingKeys: String, CodingKey { case area, add, subtract, intersect, invert, luminance, color, depth, measure, grow, refine }

    // Masks saved before areas could be combined have only an area, invert and ranges.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        area = try container.decode(MaskArea.self, forKey: .area)
        add = try container.decodeIfPresent([MaskArea].self, forKey: .add) ?? []
        subtract = try container.decodeIfPresent([MaskArea].self, forKey: .subtract) ?? []
        intersect = try container.decodeIfPresent([MaskArea].self, forKey: .intersect) ?? []
        invert = try container.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        luminance = try container.decodeIfPresent(ValueRange.self, forKey: .luminance)
        color = try container.decodeIfPresent(HueRange.self, forKey: .color)
        depth = try container.decodeIfPresent(ValueRange.self, forKey: .depth)
        measure = try container.decodeIfPresent(String.self, forKey: .measure) ?? "current"
        grow = try container.decodeIfPresent(Double.self, forKey: .grow) ?? 0
        refine = try container.decodeIfPresent(Double.self, forKey: .refine) ?? 0
    }

    static let maxAreas = 8
    static let maxObjectPoints = 16
    static let maxOutlinePoints = 400
    static let maxStrokes = 40
    static let maxStrokePoints = 400

    /// Checks a mask from a script or a saved document.
    public static func parse(_ path: String, _ value: JSONValue) throws -> Mask {
        let members = try checkKeys(path, value, ["area", "subtract", "intersect", "invert", "luminance", "color", "depth", "measure", "grow", "refine"])
        guard let areaValue = members["area"] else {
            throw StateError("\(path).area is required: an area, or a list of areas to join (types: \(Specs.maskAreas.joined(separator: ", ")))")
        }
        let joined = try parseAreas("\(path).area", areaValue)
        guard let first = joined.first else { throw StateError("\(path).area must have at least one area") }
        var mask = Mask(area: first)
        mask.add = Array(joined.dropFirst())
        if let value = members["subtract"], value != .null { mask.subtract = try parseAreas("\(path).subtract", value) }
        if let value = members["intersect"], value != .null { mask.intersect = try parseAreas("\(path).intersect", value) }
        if let value = members["invert"], value != .null {
            guard let flag = value.boolValue else { throw StateError("\(path).invert must be true or false, got \(value.described)") }
            mask.invert = flag
        }
        if let value = members["luminance"], value != .null { mask.luminance = try ValueRange.parse("\(path).luminance", value) }
        if let value = members["depth"], value != .null { mask.depth = try ValueRange.parse("\(path).depth", value) }
        if let value = members["color"], value != .null {
            let range = try checkKeys("\(path).color", value, ["hue", "range"])
            guard let hueValue = range["hue"] else { throw StateError("\(path).color needs a hue") }
            let hue = try checkNumber("\(path).color.hue", hueValue, (0, 360))
            let width = try range["range"].map { try checkNumber("\(path).color.range", $0, (10, 180)) } ?? 60
            mask.color = HueRange(hue: hue, range: width)
        }
        if let value = members["measure"], value != .null {
            guard let measure = value.stringValue, ["current", "original"].contains(measure) else {
                throw StateError("\(path).measure must be \"current\" or \"original\", got \(value.described)")
            }
            mask.measure = measure
        }
        if let value = members["grow"], value != .null { mask.grow = try checkNumber("\(path).grow", value, (-0.05, 0.05)) }
        if let value = members["refine"], value != .null { mask.refine = try checkNumber("\(path).refine", value, (0, 1)) }
        return mask
    }

    /// One area, or a list of them.
    static func parseAreas(_ path: String, _ value: JSONValue) throws -> [MaskArea] {
        guard let list = value.arrayValue else { return [try parseArea(path, value)] }
        guard !list.isEmpty, list.count <= maxAreas else { throw StateError("\(path) must list 1 to \(maxAreas) areas, got \(list.count)") }
        return try list.enumerated().map { try parseArea("\(path)[\($0.offset)]", $0.element) }
    }

    static func parseArea(_ path: String, _ value: JSONValue) throws -> MaskArea {
        guard let members = value.objectValue else { throw StateError("\(path) must be an object with a type, got \(value.described)") }
        guard let type = members["type"]?.stringValue, Specs.maskAreas.contains(type) else {
            throw StateError("\(path).type must be one of \(Specs.maskAreas.map { "\"\($0)\"" }.joined(separator: ", ")), got \((members["type"] ?? .null).described)")
        }
        var area = MaskArea(type: type)
        let position = (min: -0.5, max: 1.5)
        func point(_ path: String, _ value: JSONValue?, within range: (min: Double, max: Double) = position) throws -> [Double] {
            guard let pair = value?.arrayValue, pair.count == 2 else {
                throw StateError("\(path) must be an [x, y] point, got \((value ?? .null).described)")
            }
            return [try checkNumber("\(path)[0]", pair[0], range), try checkNumber("\(path)[1]", pair[1], range)]
        }
        func points(_ path: String, _ value: JSONValue?, count: ClosedRange<Int>, within range: (min: Double, max: Double) = position) throws -> [[Double]] {
            guard let list = value?.arrayValue, count.contains(list.count) else {
                throw StateError("\(path) must be a list of \(count.lowerBound) to \(count.upperBound) [x, y] points, got \((value ?? .null).described)")
            }
            return try list.enumerated().map { try point("\(path)[\($0.offset)]", $0.element, within: range) }
        }
        switch type {
        case "radial":
            let input = try checkKeys(path, value, ["type", "x", "y", "width", "height", "angle", "feather"])
            for key in ["x", "y", "width", "height"] where input[key] == nil {
                throw StateError("\(path) of type \"radial\" needs x, y, width and height")
            }
            area.x = try checkNumber("\(path).x", input["x"]!, position)
            area.y = try checkNumber("\(path).y", input["y"]!, position)
            area.width = try checkNumber("\(path).width", input["width"]!, (0.02, 3))
            area.height = try checkNumber("\(path).height", input["height"]!, (0.02, 3))
            if let value = input["angle"] { area.angle = try checkNumber("\(path).angle", value, (-180, 180)) }
            if let value = input["feather"] { area.feather = try checkNumber("\(path).feather", value, (0, 1)) }
        case "linear":
            let input = try checkKeys(path, value, ["type", "from", "to"])
            area.from = try point("\(path).from", input["from"])
            area.to = try point("\(path).to", input["to"])
            guard hypot(area.to[0] - area.from[0], area.to[1] - area.from[1]) >= 0.01 else {
                throw StateError("\(path).from and \(path).to must be at least 0.01 apart")
            }
        case "object":
            let input = try checkKeys(path, value, ["type", "points", "exclude"])
            area.points = try points("\(path).points", input["points"], count: 1...maxObjectPoints, within: (0, 1))
            if let value = input["exclude"], value != .null {
                area.exclude = try points("\(path).exclude", value, count: 0...maxObjectPoints, within: (0, 1))
            }
            guard area.points.count + area.exclude.count <= maxObjectPoints else {
                throw StateError("\(path) can have at most \(maxObjectPoints) points and exclude points together, got \(area.points.count + area.exclude.count)")
            }
        case "outline":
            let input = try checkKeys(path, value, ["type", "points", "feather"])
            area.points = try points("\(path).points", input["points"], count: 3...maxOutlinePoints)
            area.feather = try input["feather"].map { try checkNumber("\(path).feather", $0, (0, 0.1)) } ?? 0.003
        case "brush":
            let input = try checkKeys(path, value, ["type", "strokes", "size", "feather"])
            guard let strokes = input["strokes"]?.arrayValue, (1...maxStrokes).contains(strokes.count) else {
                throw StateError("\(path).strokes must be a list of 1 to \(maxStrokes) strokes, each a list of [x, y] points, got \((input["strokes"] ?? .null).described)")
            }
            area.strokes = try strokes.enumerated().map { try points("\(path).strokes[\($0.offset)]", $0.element, count: 1...maxStrokePoints) }
            area.size = try input["size"].map { try checkNumber("\(path).size", $0, (0.002, 0.5)) } ?? 0.03
            area.feather = try input["feather"].map { try checkNumber("\(path).feather", $0, (0, 0.1)) } ?? area.size / 4
        default:
            _ = try checkKeys(path, value, ["type"])
        }
        return area
    }
}

/// An adjustment to part of the photo: a mask and what to change inside it.
public struct LocalAdjustment: Codable, Equatable, Sendable {
    public var name: String
    public var mask: Mask
    /// Every key of `Specs.localAdjustments`; 0 is no change.
    public var adjust: [String: Double]

    public init(name: String, mask: Mask) {
        self.name = name
        self.mask = mask
        adjust = Dictionary(uniqueKeysWithValues: Specs.localAdjustments.map { ($0.name, $0.defaultValue) })
    }

    public var json: JSONValue {
        ["name": .string(name), "mask": mask.json, "adjust": .object(adjust.mapValues { .number($0) })]
    }

    /// True when it changes nothing, wherever its mask is.
    public var isIdentity: Bool { adjust.values.allSatisfy { $0 == 0 } }

    public static func cleanName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }
}
