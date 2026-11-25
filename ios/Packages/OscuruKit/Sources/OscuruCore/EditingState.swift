import Foundation

/// One development setting: its name, range and meaning. The validators, the documentation given
/// to the model, and the app all read these tables, so they cannot drift apart.
public struct ParamSpec: Sendable, Equatable {
    public let name: String
    public let min: Double
    public let max: Double
    public let defaultValue: Double
    public let unit: String
    public let description: String

    init(_ name: String, _ min: Double, _ max: Double, start defaultValue: Double = 0, unit: String = "", _ description: String) {
        self.name = name
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.unit = unit
        self.description = description
    }
}

public enum Specs {
    public static let global: [ParamSpec] = [
        ParamSpec("exposureEV", -5, 5, unit: "stops", "Exposure compensation in photographic stops, applied to linear scene data (in the RAW decoder for RAW files)."),
        ParamSpec("contrast", -100, 100, "Global contrast around mid-grey. Positive is an S-curve, negative flattens."),
        ParamSpec("highlights", -100, 100, "Negative recovers bright areas (local, keeps their contrast); positive brightens them."),
        ParamSpec("shadows", -100, 100, "Positive opens dark areas (local, keeps their contrast); negative deepens them."),
        ParamSpec("whites", -100, 100, "Moves the white point: positive brightens the top of the range and can clip, negative pulls it down."),
        ParamSpec("blacks", -100, 100, "Moves the black point: negative deepens and can clip, positive lifts (a matte look)."),
        ParamSpec("temperature", 2000, 25000, start: 6500, unit: "K", "White balance in Kelvin, as in Camera Raw: a higher value makes the photo warmer."),
        ParamSpec("tint", -150, 150, "White balance tint: negative is greener, positive is more magenta."),
        ParamSpec("texture", -100, 100, "Fine local contrast (small details). Negative smooths."),
        ParamSpec("clarity", -100, 100, "Mid-size local contrast. Negative gives a soft glow."),
        ParamSpec("dehaze", -100, 100, "Approximate global dehaze: positive removes a veil (deeper blacks, more colour), negative adds one."),
        ParamSpec("vibrance", -100, 100, "Saturation that favours muted colours and protects skin tones."),
        ParamSpec("saturation", -100, 100, "Uniform saturation. -100 is black and white, +100 doubles colourfulness."),
        ParamSpec("vignette", -100, 100, "Negative darkens the corners of the cropped frame, positive lightens them."),
    ]

    public static let hsl: [ParamSpec] = [
        ParamSpec("hue", -100, 100, "Shifts the hue of this colour range; ±100 is about ±30° around the colour wheel."),
        ParamSpec("saturation", -100, 100, "Saturation of this colour range. -100 removes its colour."),
        ParamSpec("luminance", -100, 100, "Brightness of this colour range."),
    ]

    public static let grading: [ParamSpec] = [
        ParamSpec("hue", 0, 360, unit: "°", "Hue of the tint (0 red, 60 yellow, 120 green, 180 cyan, 240 blue, 300 magenta)."),
        ParamSpec("saturation", 0, 1, "Strength of the tint. 0 is off; 0.05–0.2 is a typical grade."),
        ParamSpec("luminance", -1, 1, "Darkens or brightens this tonal range."),
    ]

    public static let gradingMix: [ParamSpec] = [
        ParamSpec("blending", 0, 1, start: 0.5, "How much the three tonal ranges overlap. 0 is separated, 1 is broad."),
        ParamSpec("balance", -1, 1, "Shifts the split between ranges: positive gives highlights more of the image, negative shadows."),
    ]

    public static let detail: [ParamSpec] = [
        ParamSpec("sharpening", 0, 100, "Sharpening amount."),
        ParamSpec("noiseReduction", 0, 100, "Luminance noise reduction."),
        ParamSpec("colorNoiseReduction", 0, 100, "Colour noise reduction (RAW files only)."),
    ]

    public static let grain: [ParamSpec] = [
        ParamSpec("amount", 0, 100, "Strength of film grain. 0 is off; 10 to 30 is subtle, 40 and above is strong."),
        ParamSpec("size", 0, 100, start: 25, "Grain size relative to the frame: 0 is very fine, like slow film; 100 is coarse, like pushed fast film."),
        ParamSpec("roughness", 0, 100, start: 50, "How uneven the grain is: 0 is even and smooth, 100 is clumpy."),
    ]

    public static let halation: [ParamSpec] = [
        ParamSpec("amount", 0, 100, "Strength of halation, the warm red glow film shows around bright highlights. 0 is off; 10 to 40 is typical."),
        ParamSpec("radius", 0, 100, start: 30, "How far the glow spreads, relative to the frame."),
        ParamSpec("threshold", 0, 100, start: 70, "How bright an area must be to glow: higher keeps it to the brightest highlights."),
    ]

    /// What a local adjustment can change inside its mask. Each is relative to the rest of the photo: 0 is no change.
    public static let localAdjustments: [ParamSpec] = [
        ParamSpec("exposureEV", -4, 4, unit: "stops", "Brightness of the area, in stops."),
        ParamSpec("contrast", -100, 100, "Contrast inside the area."),
        ParamSpec("highlights", -100, 100, "Negative darkens the area's bright tones, positive brightens them."),
        ParamSpec("shadows", -100, 100, "Positive opens the area's dark tones, negative deepens them."),
        ParamSpec("temperature", -100, 100, "Positive is warmer than the rest of the photo, negative cooler."),
        ParamSpec("tint", -100, 100, "Positive is more magenta than the rest of the photo, negative greener."),
        ParamSpec("saturation", -100, 100, "Saturation inside the area. -100 removes its colour."),
        ParamSpec("clarity", -100, 100, "Mid-size local contrast inside the area. Negative softens."),
        ParamSpec("dehaze", -100, 100, "Positive removes a veil inside the area, negative adds one."),
    ]

    public static let maskAreas = ["object", "subject", "people", "radial", "linear", "frame", "outline", "brush"]
    public static let maxLocalAdjustments = 8

    public static let cropAngle = ParamSpec(
        "angle", -45, 45, unit: "°",
        "Straighten angle. Positive turns the photo clockwise. The frame is trimmed so no empty corners show.")

    public static let colorRanges = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
    public static let curveChannels = ["rgb", "red", "green", "blue"]
    public static let gradingRanges = ["shadows", "midtones", "highlights"]
    public static let resetSections = ["all", "light", "color", "curves", "hsl", "grading", "detail", "effects", "local", "crop", "layout"]

    public static let maxCurvePoints = 16
    public static let minCurveGap = 0.004
    public static let minCropSize = 0.05

    static let lightKeys = ["exposureEV", "contrast", "highlights", "shadows", "whites", "blacks"]
    static let colorKeys = ["temperature", "tint", "vibrance", "saturation"]
    static let effectKeys = ["texture", "clarity", "dehaze", "vignette"]
}

/// Thrown for any value that is out of range, of the wrong kind, or unknown. The message names the
/// setting and what is valid, because its reader is usually the model that wrote the script.
public struct StateError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Where a photo's settings start, when that is not the generic default: the as-shot white balance
/// and the RAW decoder's own sharpening and noise reduction.
public struct PhotoDefaults: Codable, Equatable, Sendable {
    public var temperature: Double
    public var tint: Double
    public var sharpening: Double
    public var noiseReduction: Double
    public var colorNoiseReduction: Double
    /// A collage's arrangement as it was made; nil for a photo.
    public var layout: CollageLayout?
    /// How the camera framed the photo when it was zoomed between lenses: its settings start with
    /// this crop, and the rest of the frame is still there to zoom out to. Nil for the whole frame.
    public var framing: Crop?

    public init(
        temperature: Double = 6500, tint: Double = 0, sharpening: Double = 0, noiseReduction: Double = 0, colorNoiseReduction: Double = 0,
        layout: CollageLayout? = nil, framing: Crop? = nil
    ) {
        self.temperature = temperature
        self.tint = tint
        self.sharpening = sharpening
        self.noiseReduction = noiseReduction
        self.colorNoiseReduction = colorNoiseReduction
        self.layout = layout
        self.framing = framing
    }
}

public struct Grading: Codable, Equatable, Sendable {
    public var shadows: [String: Double]
    public var midtones: [String: Double]
    public var highlights: [String: Double]
    public var blending: Double
    public var balance: Double

    public subscript(range: String) -> [String: Double] {
        get { range == "shadows" ? shadows : range == "midtones" ? midtones : highlights }
        set {
            if range == "shadows" { shadows = newValue } else if range == "midtones" { midtones = newValue } else { highlights = newValue }
        }
    }
}

/// Order of operations: flips, then rotation, then straightening (which trims the frame), then the
/// crop rectangle, given as fractions of that trimmed frame from its top-left corner.
public struct Crop: Codable, Equatable, Sendable {
    public var x: Double = 0
    public var y: Double = 0
    public var width: Double = 1
    public var height: Double = 1
    public var angle: Double = 0
    /// Quarter turns clockwise, in degrees: 0, 90, 180 or 270.
    public var rotation: Int = 0
    public var flipHorizontal = false
    public var flipVertical = false

    public init() {}

    /// The middle of the frame, `zoom` times closer: what a camera zoomed past its lens frames.
    public static func centered(zoom: Double) -> Crop {
        var crop = Crop()
        let side = 1 / max(1, zoom)
        crop.x = (1 - side) / 2
        crop.y = (1 - side) / 2
        crop.width = side
        crop.height = side
        return crop
    }
}

/// The non-destructive editing state: plain, serializable data that fully describes how a photo is
/// developed. Its shape is exactly the JSON that scripts and the model see.
///
/// Every mutating function validates first, so a state that exists is always a valid one.
public struct EditingState: Codable, Equatable, Sendable {
    public var global: [String: Double]
    public var curves: [String: [[Double]]]
    public var hsl: [String: [String: Double]]
    public var grading: Grading
    public var detail: [String: Double]
    /// Film grain and halation.
    public var grain: [String: Double]
    public var halation: [String: Double]
    /// Adjustments to parts of the photo, applied in order.
    public var local: [LocalAdjustment]
    public var crop: Crop
    /// How a collage's pieces are arranged; nil for a photo.
    public var layout: CollageLayout?

    static let identityCurve: [[Double]] = [[0, 0], [1, 1]]

    static func defaults(_ specs: [ParamSpec]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: specs.map { ($0.name, $0.defaultValue) })
    }

    enum CodingKeys: String, CodingKey {
        case global, curves, hsl, grading, detail, grain, halation, local, crop, layout
    }

    /// Reads a saved state. Photos saved before grain, halation and local adjustments existed have none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        global = try container.decode([String: Double].self, forKey: .global)
        curves = try container.decode([String: [[Double]]].self, forKey: .curves)
        hsl = try container.decode([String: [String: Double]].self, forKey: .hsl)
        grading = try container.decode(Grading.self, forKey: .grading)
        detail = try container.decode([String: Double].self, forKey: .detail)
        grain = try container.decodeIfPresent([String: Double].self, forKey: .grain) ?? EditingState.defaults(Specs.grain)
        halation = try container.decodeIfPresent([String: Double].self, forKey: .halation) ?? EditingState.defaults(Specs.halation)
        local = try container.decodeIfPresent([LocalAdjustment].self, forKey: .local) ?? []
        crop = try container.decode(Crop.self, forKey: .crop)
        layout = try container.decodeIfPresent(CollageLayout.self, forKey: .layout)
    }

    /// The state of an untouched photo.
    public init(defaults: PhotoDefaults = PhotoDefaults()) {
        func start(_ value: Double, _ spec: ParamSpec) -> Double {
            value.isFinite ? Swift.min(spec.max, Swift.max(spec.min, value.rounded())) : spec.defaultValue
        }
        var global: [String: Double] = [:]
        for spec in Specs.global { global[spec.name] = spec.defaultValue }
        global["temperature"] = start(defaults.temperature, Specs.global[6])
        global["tint"] = start(defaults.tint, Specs.global[7])
        self.global = global
        curves = Dictionary(uniqueKeysWithValues: Specs.curveChannels.map { ($0, EditingState.identityCurve) })
        let zero = ["hue": 0.0, "saturation": 0.0, "luminance": 0.0]
        hsl = Dictionary(uniqueKeysWithValues: Specs.colorRanges.map { ($0, zero) })
        grading = Grading(shadows: zero, midtones: zero, highlights: zero, blending: 0.5, balance: 0)
        detail = [
            "sharpening": start(defaults.sharpening, Specs.detail[0]),
            "noiseReduction": start(defaults.noiseReduction, Specs.detail[1]),
            "colorNoiseReduction": start(defaults.colorNoiseReduction, Specs.detail[2]),
        ]
        grain = EditingState.defaults(Specs.grain)
        halation = EditingState.defaults(Specs.halation)
        local = []
        crop = defaults.framing ?? Crop()
        layout = defaults.layout
    }

    public func value(_ name: String) -> Double { global[name] ?? 0 }

    // MARK: Validated changes

    /// Sets global adjustments to the given absolute values. Settings left out keep their value.
    public mutating func adjust(_ settings: JSONValue) throws {
        for (key, value) in try checkNumbers("adjust", settings, Specs.global) { global[key] = value }
    }

    public mutating func setCurve(channel: JSONValue, points: JSONValue) throws {
        let name = try oneOf("curve channel", channel, Specs.curveChannels)
        curves[name] = try EditingState.normalizeCurve("curves.\(name)", points)
    }

    public mutating func adjustHSL(color: JSONValue, adjustments: JSONValue) throws {
        let name = try oneOf("hsl colour", color, Specs.colorRanges)
        for (key, value) in try checkNumbers("hsl.\(name)", adjustments, Specs.hsl) { hsl[name]![key] = value }
    }

    public mutating func setGrading(range: JSONValue, settings: JSONValue) throws {
        let name = try oneOf("grading range", range, Specs.gradingRanges)
        var values = grading[name]
        for (key, value) in try checkNumbers("grading.\(name)", settings, Specs.grading) { values[key] = value }
        grading[name] = values
    }

    public mutating func configureGrading(_ settings: JSONValue) throws {
        let values = try checkNumbers("grading", settings, Specs.gradingMix)
        if let blending = values["blending"] { grading.blending = blending }
        if let balance = values["balance"] { grading.balance = balance }
    }

    public mutating func setDetail(_ settings: JSONValue) throws {
        for (key, value) in try checkNumbers("detail", settings, Specs.detail) { detail[key] = value }
    }

    public mutating func setGrain(_ settings: JSONValue) throws {
        for (key, value) in try checkNumbers("grain", settings, Specs.grain) { grain[key] = value }
    }

    public mutating func setHalation(_ settings: JSONValue) throws {
        for (key, value) in try checkNumbers("halation", settings, Specs.halation) { halation[key] = value }
    }

    /// Creates the local adjustment called `name`, or changes it. A new one needs a mask; a mask
    /// given replaces the old one; adjust values left out keep their value (0 for a new one).
    public mutating func setLocal(name nameValue: JSONValue, settings: JSONValue) throws {
        guard let raw = nameValue.stringValue, !LocalAdjustment.cleanName(raw).isEmpty else {
            throw StateError("a local adjustment needs a name: a non-empty string, got \(nameValue.described)")
        }
        let name = LocalAdjustment.cleanName(raw)
        let path = "local \"\(name)\""
        let input = try checkKeys(path, settings, ["mask", "adjust"])
        let index = local.firstIndex { $0.name.lowercased() == name.lowercased() }
        var adjustment: LocalAdjustment
        if let index {
            adjustment = local[index]
            if let mask = input["mask"], mask != .null { adjustment.mask = try Mask.parse("\(path).mask", mask) }
        } else {
            guard let mask = input["mask"], mask != .null else {
                throw StateError("\(path) does not exist yet, so it needs a mask. Existing: \(local.isEmpty ? "none" : local.map(\.name).joined(separator: ", "))")
            }
            guard local.count < Specs.maxLocalAdjustments else {
                throw StateError("a photo can have at most \(Specs.maxLocalAdjustments) local adjustments; remove one first")
            }
            adjustment = LocalAdjustment(name: name, mask: try Mask.parse("\(path).mask", mask))
        }
        if let values = input["adjust"], values != .null {
            for (key, value) in try checkNumbers("\(path).adjust", values, Specs.localAdjustments) { adjustment.adjust[key] = value }
        }
        if let index { local[index] = adjustment } else { local.append(adjustment) }
    }

    public mutating func removeLocal(name nameValue: JSONValue) throws {
        guard let name = nameValue.stringValue.map(LocalAdjustment.cleanName), let index = local.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw StateError("there is no local adjustment named \(nameValue.described). Existing: \(local.isEmpty ? "none" : local.map(\.name).joined(separator: ", "))")
        }
        local.remove(at: index)
    }

    public func localAdjustment(named nameValue: JSONValue) throws -> LocalAdjustment {
        guard let name = nameValue.stringValue.map(LocalAdjustment.cleanName), let found = local.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw StateError("there is no local adjustment named \(nameValue.described). Existing: \(local.isEmpty ? "none" : local.map(\.name).joined(separator: ", "))")
        }
        return found
    }

    public mutating func setCrop(_ settings: JSONValue) throws {
        let allowed = ["x", "y", "width", "height", "angle", "rotation", "flipHorizontal", "flipVertical"]
        let input = try checkKeys("crop", settings, allowed)
        var next = crop
        let unit = (min: 0.0, max: 1.0)
        let size = (min: Specs.minCropSize, max: 1.0)
        if let value = input["x"] { next.x = try checkNumber("crop.x", value, unit) }
        if let value = input["y"] { next.y = try checkNumber("crop.y", value, unit) }
        if let value = input["width"] { next.width = try checkNumber("crop.width", value, size) }
        if let value = input["height"] { next.height = try checkNumber("crop.height", value, size) }
        if let value = input["angle"] { next.angle = try checkNumber("crop.angle", value, (Specs.cropAngle.min, Specs.cropAngle.max)) }
        if let value = input["rotation"] {
            guard let number = value.doubleValue, [0, 90, 180, 270].contains(number) else {
                throw StateError("crop.rotation must be 0, 90, 180 or 270, got \(value.described)")
            }
            next.rotation = Int(number)
        }
        for key in ["flipHorizontal", "flipVertical"] {
            guard let value = input[key] else { continue }
            guard let flag = value.boolValue else { throw StateError("crop.\(key) must be true or false, got \(value.described)") }
            if key == "flipHorizontal" { next.flipHorizontal = flag } else { next.flipVertical = flag }
        }
        let epsilon = 1e-6
        if next.x + next.width > 1 + epsilon || next.y + next.height > 1 + epsilon {
            throw StateError(
                "crop rectangle leaves the frame: x + width and y + height must be at most 1 (got x \(formatNumber(next.x)), width \(formatNumber(next.width)), y \(formatNumber(next.y)), height \(formatNumber(next.height)))"
            )
        }
        crop = next
    }

    /// Puts one section (or everything) back to how the photo was opened.
    public mutating func reset(section: JSONValue = "all", defaults: PhotoDefaults) throws {
        let name = try oneOf("reset section", section, Specs.resetSections)
        let fresh = EditingState(defaults: defaults)
        func restore(_ keys: [String]) {
            for key in keys { global[key] = fresh.global[key] }
        }
        switch name {
        case "all": self = fresh
        case "light": restore(Specs.lightKeys)
        case "color": restore(Specs.colorKeys)
        case "curves": curves = fresh.curves
        case "hsl": hsl = fresh.hsl
        case "grading": grading = fresh.grading
        case "detail":
            detail = fresh.detail
            restore(Specs.effectKeys)
        case "effects":
            grain = fresh.grain
            halation = fresh.halation
        case "local": local = []
        case "layout": layout = fresh.layout
        default: crop = fresh.crop
        }
    }

    /// Checks and normalizes curve control points: sorted by input, inside 0–1, with distinct inputs.
    public static func normalizeCurve(_ path: String, _ points: JSONValue) throws -> [[Double]] {
        guard let list = points.arrayValue else { throw StateError("\(path) must be an array of [input, output] points") }
        guard list.count >= 2, list.count <= Specs.maxCurvePoints else {
            throw StateError("\(path) needs between 2 and \(Specs.maxCurvePoints) points, got \(list.count)")
        }
        var result: [[Double]] = []
        for (index, point) in list.enumerated() {
            guard let pair = point.arrayValue, pair.count == 2 else { throw StateError("\(path)[\(index)] must be an [input, output] pair") }
            result.append([
                try checkNumber("\(path)[\(index)][0]", pair[0], (0, 1)),
                try checkNumber("\(path)[\(index)][1]", pair[1], (0, 1)),
            ])
        }
        result.sort { $0[0] < $1[0] }
        for index in 1..<result.count where result[index][0] - result[index - 1][0] < Specs.minCurveGap {
            throw StateError(
                "\(path) has two points with (almost) the same input \(formatNumber(result[index][0])); inputs must differ by at least \(formatNumber(Specs.minCurveGap))"
            )
        }
        return result
    }

    // MARK: JSON

    public var json: JSONValue {
        func numbers(_ values: [String: Double]) -> JSONValue { .object(values.mapValues { .number($0) }) }
        var json: JSONValue = [
            "global": numbers(global),
            "curves": .object(curves.mapValues { points in .array(points.map { .array($0.map { .number($0) }) }) }),
            "hsl": .object(hsl.mapValues(numbers)),
            "grading": [
                "shadows": numbers(grading.shadows),
                "midtones": numbers(grading.midtones),
                "highlights": numbers(grading.highlights),
                "blending": .number(grading.blending),
                "balance": .number(grading.balance),
            ],
            "detail": numbers(detail),
            "grain": numbers(grain),
            "halation": numbers(halation),
            "local": .array(local.map(\.json)),
            "crop": [
                "x": .number(crop.x), "y": .number(crop.y), "width": .number(crop.width), "height": .number(crop.height),
                "angle": .number(crop.angle), "rotation": .number(Double(crop.rotation)),
                "flipHorizontal": .bool(crop.flipHorizontal), "flipVertical": .bool(crop.flipVertical),
            ],
        ]
        if let layout, case .object(var members) = json {
            members["layout"] = layout.json
            json = .object(members)
        }
        return json
    }

    /// Rebuilds a state from untrusted data (a saved document), checking every value.
    public init(json: JSONValue) throws {
        guard json.objectValue != nil else { throw StateError("editing state must be an object") }
        self.init()
        if let value = json["global"] { try adjust(value) }
        if let value = json["curves"] {
            for (channel, points) in try checkKeys("curves", value, Specs.curveChannels) { try setCurve(channel: .string(channel), points: points) }
        }
        if let value = json["hsl"] {
            for (color, adjustments) in try checkKeys("hsl", value, Specs.colorRanges) { try adjustHSL(color: .string(color), adjustments: adjustments) }
        }
        if let value = json["grading"] {
            let members = try checkKeys("grading", value, Specs.gradingRanges + ["blending", "balance"])
            var mix: [String: JSONValue] = [:]
            for (key, member) in members {
                if Specs.gradingRanges.contains(key) { try setGrading(range: .string(key), settings: member) } else { mix[key] = member }
            }
            try configureGrading(.object(mix))
        }
        if let value = json["detail"] { try setDetail(value) }
        if let value = json["grain"] { try setGrain(value) }
        if let value = json["halation"] { try setHalation(value) }
        if let value = json["local"] {
            guard let list = value.arrayValue else { throw StateError("local must be an array") }
            for item in list { try setLocal(name: item["name"] ?? .null, settings: .object((item.objectValue ?? [:]).filter { $0.key != "name" })) }
        }
        if let value = json["crop"] { try setCrop(value) }
        if let value = json["layout"], value != .null {
            layout = CollageLayout(aspect: 1, cells: [])
            try setLayout(value, pieces: CollageLayout.maxPieces)
        }
    }

    // MARK: Changes

    public struct Change: Equatable, Sendable {
        public let path: String
        public let from: JSONValue
        public let to: JSONValue

        public var json: JSONValue { ["path": .string(path), "from": from, "to": to] }
    }

    /// What differs from `before`, one entry per setting (a whole curve counts as one), in a stable order.
    public func changes(from before: EditingState) -> [Change] {
        var changes: [Change] = []
        func compare(_ path: String, _ old: JSONValue, _ new: JSONValue) {
            if let oldMembers = old.objectValue, let newMembers = new.objectValue {
                for key in newMembers.keys.sorted() {
                    compare(path.isEmpty ? key : "\(path).\(key)", oldMembers[key] ?? .null, newMembers[key]!)
                }
            } else if old != new {
                changes.append(Change(path: path, from: old, to: new))
            }
        }
        let order = ["global", "curves", "hsl", "grading", "detail", "grain", "halation", "local", "crop", "layout"]
        let old = before.json
        let new = json
        for section in order { compare(section, old[section] ?? .null, new[section] ?? .null) }
        return changes
    }

    public func isIdentityCurve(_ channel: String) -> Bool {
        (curves[channel] ?? []).allSatisfy { abs($0[0] - $0[1]) < 1e-6 }
    }

    /// How much of the frame survives straightening by `angle` degrees: the largest rectangle with
    /// the frame's own proportions that fits inside the turned frame, as a fraction of its sides.
    public static func straightenScale(angle: Double, aspect: Double) -> Double {
        let radians = abs(angle) * .pi / 180
        let long = Swift.max(aspect, 1 / aspect)
        return 1 / (cos(radians) + long * sin(radians))
    }
}

// MARK: Checks

func checkNumber(_ path: String, _ value: JSONValue, _ range: (min: Double, max: Double)) throws -> Double {
    guard let number = value.doubleValue, number.isFinite else {
        throw StateError("\(path) must be a finite number, got \(value.described)")
    }
    guard number >= range.min, number <= range.max else {
        throw StateError("\(path) must be between \(formatNumber(range.min)) and \(formatNumber(range.max)), got \(formatNumber(number))")
    }
    return number
}

func checkKeys(_ path: String, _ value: JSONValue, _ allowed: [String]) throws -> [String: JSONValue] {
    guard let members = value.objectValue else { throw StateError("\(path) must be an object, got \(value.described)") }
    for key in members.keys.sorted() where !allowed.contains(key) {
        throw StateError("\(path) has no setting \"\(key)\". Valid settings: \(allowed.joined(separator: ", "))")
    }
    return members
}

func checkNumbers(_ path: String, _ value: JSONValue, _ specs: [ParamSpec]) throws -> [String: Double] {
    let members = try checkKeys(path, value, specs.map(\.name))
    var result: [String: Double] = [:]
    for spec in specs {
        if let member = members[spec.name] { result[spec.name] = try checkNumber("\(path).\(spec.name)", member, (spec.min, spec.max)) }
    }
    return result
}

private func oneOf(_ what: String, _ value: JSONValue, _ allowed: [String]) throws -> String {
    guard let name = value.stringValue, allowed.contains(name) else {
        throw StateError("\(what) must be one of \(allowed.map { "\"\($0)\"" }.joined(separator: ", ")), got \(value.described)")
    }
    return name
}
