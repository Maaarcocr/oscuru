import Foundation

/// How the frames of one shot become the picture: part of a photo's settings when the camera kept
/// its frames (see `FrameSet`), so the assistant decides it and every version keeps its own.
///
/// The picture as a whole is merged one `Way`; `areas` are parts of it merged another, each
/// through a mask.
public struct FrameMerge: Codable, Equatable, Sendable {
    /// How the frames are lined up with the base.
    public enum Align: String, Codable, CaseIterable, Sendable {
        /// Piece by piece: whatever moved is followed too, so each part of the scene lies over itself.
        case tiles
        /// By the camera's own movement: the scene's still parts line up, and what moved in it stays
        /// where it was in each frame. With `alignOn`, by the movement of what is in that part instead.
        case camera
        /// Not at all: frames from a camera that did not move.
        case none
    }

    /// How each place of the picture is made from the frames there.
    public enum Combine: String, Codable, CaseIterable, Sendable {
        /// The base's, with the others averaged in only where they agree with it beyond noise: less
        /// noise, and no ghost of anything that moved.
        case robust
        /// All of them averaged, as one long exposure: what moved blurs along its way.
        case mean
        /// What most of them agree on: whatever passed through is gone.
        case median
        /// What most of them agree on, with anything that was brighter in some frame laid over it.
        case brightest
        /// The frame that is sharpest there: a scene in focus front to back from frames focused at
        /// different distances, or the steadiest frame at each place.
        case sharpest
    }

    /// A part of the frame as taken (before any crop, straightening, turns or flips), as fractions
    /// from its top-left corner.
    public struct Rect: Codable, Equatable, Sendable {
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

        var json: JSONValue { ["x": .number(x), "y": .number(y), "width": .number(width), "height": .number(height)] }
    }

    /// One way of merging: which frames, around which of them, lined up how, combined how, onto
    /// what grid.
    public struct Way: Codable, Equatable, Sendable {
        /// The frame the picture is built on, counted from 1: its framing, its brightness and, when
        /// combined robustly, its moment.
        public var base: Int
        /// The frames merged, in order, the base among them.
        public var use: [Int]
        public var align: Align
        /// With `align` camera: the part of the frame whose movement is followed.
        public var alignOn: Rect?
        public var combine: Combine
        /// The grid: 1 the sensor's own, 2 twice as many pixels each way, made from the samples of
        /// all the frames where they fell.
        public var scale: Int
        /// How readily a difference counts as movement rather than noise, 0 to 1: lower averages more.
        public var caution: Double

        public init(base: Int, use: [Int], align: Align = .tiles, alignOn: Rect? = nil, combine: Combine = .robust, scale: Int = 1, caution: Double = 0.5) {
            self.base = base
            self.use = use
            self.align = align
            self.alignOn = alignOn
            self.combine = combine
            self.scale = scale
            self.caution = caution
        }

        /// One frame as it was taken, alone.
        public static func single(_ frame: Int) -> Way { Way(base: frame, use: [frame]) }

        /// Only one frame, on its own grid: nothing is merged, and the picture is that frame's own file.
        public var isSingle: Bool { use.count == 1 && scale == 1 }

        /// A name for the merge that two equal ways share and no others: what its file is called.
        public var key: String {
            if isSingle { return "frame \(base)" }
            var name = "base \(base) of \(use.map(String.init).joined(separator: "."))"
            name += " \(align.rawValue)"
            if let alignOn {
                name += " on " + [alignOn.x, alignOn.y, alignOn.width, alignOn.height].map { String(Int(($0 * 1000).rounded())) }.joined(separator: ".")
            }
            name += " \(combine.rawValue)"
            if combine == .robust || combine == .median || combine == .brightest { name += " \(Int((caution * 100).rounded()))" }
            if scale != 1 { name += " x\(scale)" }
            return name
        }

        /// How far beyond the sensor's noise a difference may go and still be averaged (`BurstMerge`).
        var tolerance: Float { Float(8 * pow(4, 1 - 2 * caution)) }

        public var json: JSONValue {
            var members: [String: JSONValue] = [
                "base": .number(Double(base)), "use": .array(use.map { .number(Double($0)) }), "align": .string(align.rawValue),
                "combine": .string(combine.rawValue), "scale": .number(Double(scale)), "caution": .number(caution),
            ]
            if let alignOn { members["alignOn"] = alignOn.json }
            return .object(members)
        }

        static let keys = ["base", "use", "align", "alignOn", "combine", "scale", "caution", "movement"]

        // Saved before align and combine existed, a way had a movement: one of four of their pairs.
        private enum CodingKeys: String, CodingKey { case base, use, align, alignOn, combine, scale, caution, movement }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            base = try container.decode(Int.self, forKey: .base)
            use = try container.decode([Int].self, forKey: .use)
            caution = try container.decodeIfPresent(Double.self, forKey: .caution) ?? 0.5
            scale = try container.decodeIfPresent(Int.self, forKey: .scale) ?? 1
            alignOn = try container.decodeIfPresent(Rect.self, forKey: .alignOn)
            if let combine = try container.decodeIfPresent(Combine.self, forKey: .combine) {
                self.combine = combine
                align = try container.decodeIfPresent(Align.self, forKey: .align) ?? Way.align(for: combine)
            } else {
                (align, combine) = Way.legacy(try container.decodeIfPresent(String.self, forKey: .movement) ?? "freeze")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(base, forKey: .base)
            try container.encode(use, forKey: .use)
            try container.encode(align, forKey: .align)
            try container.encodeIfPresent(alignOn, forKey: .alignOn)
            try container.encode(combine, forKey: .combine)
            try container.encode(scale, forKey: .scale)
            try container.encode(caution, forKey: .caution)
        }

        /// The lining up that goes with a way of combining, when none is asked for: piece by piece
        /// to keep one moment or pick the sharpest, by the camera for the rest (so what moved stays
        /// where it was in each frame, to be blurred, removed or drawn).
        static func align(for combine: Combine) -> Align {
            combine == .robust || combine == .sharpest ? .tiles : .camera
        }

        /// What a movement of an earlier version is in these terms.
        static func legacy(_ movement: String) -> (Align, Combine) {
            switch movement {
            case "blur": return (.camera, .mean)
            case "remove": return (.camera, .median)
            case "trails": return (.camera, .brightest)
            default: return (.tiles, .robust)
            }
        }

        /// Changes the settings given, checking each against a shot of `count` frames.
        mutating func set(_ path: String, _ members: [String: JSONValue], count: Int) throws {
            func frame(_ path: String, _ value: JSONValue) throws -> Int {
                guard let number = value.doubleValue, number == number.rounded(), number >= 1, number <= Double(count) else {
                    throw StateError("\(path) must be a frame of this shot, a whole number from 1 to \(count), got \(value.described)")
                }
                return Int(number)
            }
            func choice<T: RawRepresentable & CaseIterable>(_ path: String, _ value: JSONValue, _: T.Type) throws -> T where T.RawValue == String {
                guard let name = value.stringValue, let found = T(rawValue: name) else {
                    throw StateError("\(path) must be one of \(T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")), got \(value.described)")
                }
                return found
            }
            var next = self
            if let value = members["use"], value != .null {
                if value.stringValue == "all" {
                    next.use = Array(1...count)
                } else {
                    guard let list = value.arrayValue, !list.isEmpty else {
                        throw StateError("\(path).use must be \"all\" or a list of frames, such as [1, 2, 4], got \(value.described)")
                    }
                    let frames = try list.enumerated().map { try frame("\(path).use[\($0.offset)]", $0.element) }
                    guard Set(frames).count == frames.count else { throw StateError("\(path).use names a frame twice") }
                    next.use = frames.sorted()
                }
            }
            if let value = members["base"], value != .null { next.base = try frame("\(path).base", value) }
            guard next.use.contains(next.base) else {
                throw StateError("\(path).base is frame \(next.base), which is not among the frames used (\(next.use.map(String.init).joined(separator: ", "))): set base to one of them, or add it to use")
            }
            if let value = members["movement"], value != .null {
                guard let name = value.stringValue, ["freeze", "blur", "remove", "trails"].contains(name) else {
                    throw StateError("\(path).movement is no longer a setting: use combine (and align)")
                }
                (next.align, next.combine) = Way.legacy(name)
            }
            if let value = members["combine"], value != .null {
                next.combine = try choice("\(path).combine", value, Combine.self)
                // The lining up that goes with it, unless one is given.
                if members["align"] == nil || members["align"] == .null { next.align = Way.align(for: next.combine) }
            }
            if let value = members["align"], value != .null { next.align = try choice("\(path).align", value, Align.self) }
            if let value = members["alignOn"] {
                if value == .null {
                    next.alignOn = nil
                } else {
                    let place = try checkKeys("\(path).alignOn", value, ["x", "y", "width", "height"])
                    func part(_ key: String) throws -> Double {
                        guard let number = place[key]?.doubleValue, number.isFinite, number >= 0, number <= 1 else {
                            throw StateError("\(path).alignOn.\(key) must be a number from 0 to 1, got \((place[key] ?? .null).described)")
                        }
                        return (number * 1000).rounded() / 1000
                    }
                    let rect = Rect(x: try part("x"), y: try part("y"), width: try part("width"), height: try part("height"))
                    guard rect.width >= 0.02, rect.height >= 0.02, rect.x + rect.width <= 1.001, rect.y + rect.height <= 1.001 else {
                        throw StateError("\(path).alignOn must lie inside the frame and be at least 0.02 wide and high")
                    }
                    next.alignOn = rect
                }
            }
            if next.alignOn != nil, next.align != .camera {
                throw StateError("\(path).alignOn follows the movement of one part of the frame, which only align \"camera\" does")
            }
            if let value = members["scale"], value != .null {
                guard let number = value.doubleValue, number == 1 || number == 2 else { throw StateError("\(path).scale must be 1 or 2, got \(value.described)") }
                next.scale = Int(number)
            }
            if let value = members["caution"], value != .null {
                guard let number = value.doubleValue, number.isFinite, number >= 0, number <= 1 else {
                    throw StateError("\(path).caution must be a number from 0 to 1, got \(value.described)")
                }
                next.caution = (number * 100).rounded() / 100
            }
            self = next
        }
    }

    /// A part of the picture merged its own way.
    public struct Area: Codable, Equatable, Sendable {
        public var mask: Mask
        public var way: Way

        public init(mask: Mask, way: Way) {
            self.mask = mask
            self.way = way
        }

        public var json: JSONValue {
            guard case .object(var members) = way.json else { return .null }
            members["mask"] = mask.json
            return .object(members)
        }
    }

    public var way: Way
    /// Later ones lie over earlier ones.
    public var areas: [Area]

    public static let maxAreas = 3
    /// More frames than any shot has: for checking settings read back from a saved photo.
    public static let maxFrames = 64

    public init(way: Way, areas: [Area] = []) {
        self.way = way
        self.areas = areas
    }

    /// As scripts see it: the way's settings, and `areas` each with a mask and its own.
    public var json: JSONValue {
        guard case .object(var members) = way.json else { return .null }
        members["areas"] = .array(areas.map(\.json))
        return .object(members)
    }

    /// Changes the settings given. An area starts from the picture's own way (as it is after this
    /// call) and changes what it names; `areas` given replaces them all.
    public mutating func set(_ value: JSONValue, count: Int) throws {
        let members = try checkKeys("frames", value, Way.keys + ["areas"])
        var next = self
        try next.way.set("frames", members, count: count)
        if let value = members["areas"], value != .null {
            guard let list = value.arrayValue else { throw StateError("frames.areas must be a list, got \(value.described)") }
            guard list.count <= FrameMerge.maxAreas else { throw StateError("frames.areas can hold at most \(FrameMerge.maxAreas) areas") }
            next.areas = try list.enumerated().map { index, item in
                let path = "frames.areas[\(index)]"
                let settings = try checkKeys(path, item, Way.keys + ["mask"])
                guard let mask = settings["mask"], mask != .null else { throw StateError("\(path).mask is required: the part of the picture merged this way") }
                var way = next.way
                try way.set(path, settings, count: count)
                return Area(mask: try Mask.parse("\(path).mask", mask), way: way)
            }
        }
        self = next
    }
}

extension EditingState {
    /// How a shot's frames are merged; a photo whose frames the camera did not keep has no such setting.
    public func frameMerge() throws -> FrameMerge {
        guard let frames else {
            throw StateError(
                "this photo has no frames to merge: it is one frame, or its frames were not kept. Frames are kept for photos taken in Oscuru's camera with Frames above ×1.")
        }
        return frames
    }

    /// Changes how the frames are merged, for a shot of `count` frames.
    public mutating func setFrames(_ value: JSONValue, count: Int) throws {
        var next = try frameMerge()
        try next.set(value, count: count)
        frames = next
    }
}
