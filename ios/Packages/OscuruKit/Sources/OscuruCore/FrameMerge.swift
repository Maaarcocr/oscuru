import Foundation

/// How the frames of one shot become the picture: part of a photo's settings when the camera kept
/// its frames (see `FrameSet`), so the assistant decides it and every version keeps its own.
///
/// The picture as a whole is merged one `Way`; `areas` are parts of it merged another, each
/// through a mask.
public struct FrameMerge: Codable, Equatable, Sendable {
    /// What becomes of what moved between the frames.
    public enum Movement: String, Codable, CaseIterable, Sendable {
        /// The base frame's moment: the other frames only take noise away where they agree with it.
        case freeze
        /// Everything averaged: what moved is blurred along its way, as in one long exposure.
        case blur
        /// What stayed put: whatever passed through is gone.
        case remove
        /// What stayed put, and every bright thing that moved drawn along its way.
        case trails
    }

    /// One way of merging: which frames, around which of them, and what becomes of movement.
    public struct Way: Codable, Equatable, Sendable {
        /// The frame the picture is built on, counted from 1: its moment (for `freeze`), its
        /// framing, and its brightness.
        public var base: Int
        /// The frames merged, in order, the base among them.
        public var use: [Int]
        public var movement: Movement
        /// For `freeze`, how readily a difference from the base counts as movement, 0 to 1: lower
        /// averages more (less noise, a risk of ghosts), higher keeps more of the base alone.
        public var caution: Double

        public init(base: Int, use: [Int], movement: Movement = .freeze, caution: Double = 0.5) {
            self.base = base
            self.use = use
            self.movement = movement
            self.caution = caution
        }

        /// One frame as it was taken, alone.
        public static func single(_ frame: Int) -> Way { Way(base: frame, use: [frame]) }

        /// Only one frame: nothing is merged, and the picture is that frame's own file.
        public var isSingle: Bool { use.count == 1 }

        /// A name for the merge that two equal ways share and no others: what its file is called.
        public var key: String {
            if isSingle { return "frame \(base)" }
            var name = "base \(base) of \(use.map(String.init).joined(separator: "."))"
            name += " \(movement.rawValue)"
            if movement == .freeze { name += " \(Int((caution * 100).rounded()))" }
            return name
        }

        /// How far beyond the sensor's noise a difference may go and still be averaged (`BurstMerge`).
        var tolerance: Float { Float(8 * pow(4, 1 - 2 * caution)) }

        public var json: JSONValue {
            [
                "base": .number(Double(base)), "use": .array(use.map { .number(Double($0)) }), "movement": .string(movement.rawValue),
                "caution": .number(caution),
            ]
        }

        static let keys = ["base", "use", "movement", "caution"]

        /// Changes the settings given, checking each against a shot of `count` frames.
        mutating func set(_ path: String, _ members: [String: JSONValue], count: Int) throws {
            func frame(_ path: String, _ value: JSONValue) throws -> Int {
                guard let number = value.doubleValue, number == number.rounded(), number >= 1, number <= Double(count) else {
                    throw StateError("\(path) must be a frame of this shot, a whole number from 1 to \(count), got \(value.described)")
                }
                return Int(number)
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
                guard let name = value.stringValue, let movement = Movement(rawValue: name) else {
                    throw StateError("\(path).movement must be one of \(Movement.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")), got \(value.described)")
                }
                next.movement = movement
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
