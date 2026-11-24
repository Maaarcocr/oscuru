import Foundation

/// Where a mask starts from: a shape on the frame, something found in the photo, or everything.
/// Positions are fractions of the frame as it is shown (after the crop), from its top-left corner.
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
    public var feather = 0.5
    /// Linear: full strength at `from`, fading to nothing at `to`; each an [x, y] point.
    public var from = [0.5, 0.0]
    public var to = [0.5, 0.5]

    public init(type: String) {
        self.type = type
    }

    public var json: JSONValue {
        switch type {
        case "radial":
            return [
                "type": "radial", "x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height), "angle": .number(angle),
                "feather": .number(feather),
            ]
        case "linear":
            return ["type": "linear", "from": .array(from.map { .number($0) }), "to": .array(to.map { .number($0) })]
        default:
            return ["type": .string(type)]
        }
    }
}

/// Which tones a mask keeps, by display luminance, with soft edges.
public struct LuminanceRange: Codable, Equatable, Sendable {
    public var from: Double
    public var to: Double
    public var feather: Double

    public var json: JSONValue { ["from": .number(from), "to": .number(to), "feather": .number(feather)] }
}

/// Which colours a mask keeps: hues within `range` degrees around `hue`, fading at the edges.
public struct HueRange: Codable, Equatable, Sendable {
    public var hue: Double
    public var range: Double

    public var json: JSONValue { ["hue": .number(hue), "range": .number(range)] }
}

/// Where a local adjustment applies: an area, optionally turned inside out, narrowed to tones and colours.
public struct Mask: Codable, Equatable, Sendable {
    public var area: MaskArea
    public var invert = false
    public var luminance: LuminanceRange?
    public var color: HueRange?

    public init(area: MaskArea) {
        self.area = area
    }

    public var json: JSONValue {
        var members: [String: JSONValue] = ["area": area.json, "invert": .bool(invert)]
        if let luminance { members["luminance"] = luminance.json }
        if let color { members["color"] = color.json }
        return .object(members)
    }

    /// Checks a mask from a script or a saved document.
    public static func parse(_ path: String, _ value: JSONValue) throws -> Mask {
        let members = try checkKeys(path, value, ["area", "invert", "luminance", "color"])
        guard let areaValue = members["area"] else { throw StateError("\(path).area is required: one of \(Specs.maskAreas.joined(separator: ", "))") }
        var mask = Mask(area: try parseArea("\(path).area", areaValue))
        if let value = members["invert"], value != .null {
            guard let flag = value.boolValue else { throw StateError("\(path).invert must be true or false, got \(value.described)") }
            mask.invert = flag
        }
        if let value = members["luminance"], value != .null {
            let range = try checkKeys("\(path).luminance", value, ["from", "to", "feather"])
            guard let fromValue = range["from"], let toValue = range["to"] else { throw StateError("\(path).luminance needs from and to") }
            let from = try checkNumber("\(path).luminance.from", fromValue, (0, 1))
            let to = try checkNumber("\(path).luminance.to", toValue, (0, 1))
            guard to - from >= 0.02 else { throw StateError("\(path).luminance.to must be above from (by at least 0.02), got from \(formatNumber(from)), to \(formatNumber(to))") }
            let feather = try range["feather"].map { try checkNumber("\(path).luminance.feather", $0, (0, 0.5)) } ?? 0.1
            mask.luminance = LuminanceRange(from: from, to: to, feather: feather)
        }
        if let value = members["color"], value != .null {
            let range = try checkKeys("\(path).color", value, ["hue", "range"])
            guard let hueValue = range["hue"] else { throw StateError("\(path).color needs a hue") }
            let hue = try checkNumber("\(path).color.hue", hueValue, (0, 360))
            let width = try range["range"].map { try checkNumber("\(path).color.range", $0, (10, 180)) } ?? 60
            mask.color = HueRange(hue: hue, range: width)
        }
        return mask
    }

    static func parseArea(_ path: String, _ value: JSONValue) throws -> MaskArea {
        guard let members = value.objectValue else { throw StateError("\(path) must be an object with a type, got \(value.described)") }
        guard let type = members["type"]?.stringValue, Specs.maskAreas.contains(type) else {
            throw StateError("\(path).type must be one of \(Specs.maskAreas.map { "\"\($0)\"" }.joined(separator: ", ")), got \((members["type"] ?? .null).described)")
        }
        var area = MaskArea(type: type)
        let position = (min: -0.5, max: 1.5)
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
            func point(_ key: String) throws -> [Double] {
                guard let pair = input[key]?.arrayValue, pair.count == 2 else {
                    throw StateError("\(path).\(key) must be an [x, y] point, got \((input[key] ?? .null).described)")
                }
                return [try checkNumber("\(path).\(key)[0]", pair[0], position), try checkNumber("\(path).\(key)[1]", pair[1], position)]
            }
            area.from = try point("from")
            area.to = try point("to")
            guard hypot(area.to[0] - area.from[0], area.to[1] - area.from[1]) >= 0.01 else {
                throw StateError("\(path).from and \(path).to must be at least 0.01 apart")
            }
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
