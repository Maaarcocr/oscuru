import Foundation

/// The frames of one shot, kept beside the photo's file so they can be merged another way later:
/// what the camera knows of each, and how it merged them into that file. Written once, by the
/// camera, as `frames/set.json` in the photo's folder, with each frame's own DNG beside it
/// (`frames/1.dng`, `frames/2.dng`, …) for as long as they are kept.
public struct FrameSet: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        /// The exposure it was taken at: time in seconds, and ISO.
        public var time: Double
        public var iso: Double
        /// The light it took, measured from the frames themselves, as a share of the first frame's.
        public var light: Double
        /// When it was taken, in seconds after the first.
        public var after: Double
        /// How much fine detail it holds, as a share of the sharpest frame's.
        public var sharpness: Double
        /// The share of its photosites that are blown.
        public var blown: Double
        /// How it lies against the base of the camera's own merge.
        public var report: FrameReport

        public init(time: Double, iso: Double, light: Double = 1, after: Double = 0, sharpness: Double = 1, blown: Double = 0, report: FrameReport = FrameReport()) {
            self.time = time
            self.iso = iso
            self.light = light
            self.after = after
            self.sharpness = sharpness
            self.blown = blown
            self.report = report
        }
    }

    public var frames: [Frame]
    /// How the camera merged them into the photo's file: where the photo's settings start.
    public var merge: FrameMerge.Way
    /// Whether the frames' own files are still there. Without them the photo stays as it is merged.
    public var kept: Bool

    public init(frames: [Frame], merge: FrameMerge.Way, kept: Bool = true) {
        self.frames = frames
        self.merge = merge
        self.kept = kept
    }

    /// Where a photo's frames are, beside its file.
    public static let folder = "frames"
    public static let manifest = "set.json"
    public static func fileName(of frame: Int) -> String { "\(frame).dng" }
    /// Where merges other than the camera's are kept, made when first asked for.
    public static let mergesFolder = "merges"

    /// Each frame's light, as shares of the first frame's.
    public var light: [Double] { frames.map(\.light) }

    /// How much brighter than its file a merge is to be shown (see `MergedFrame`): by as much as
    /// its dimmest frame is darker than its base.
    public func brightening(of way: FrameMerge.Way) -> Double {
        guard !way.isSingle, way.base >= 1, way.base <= frames.count else { return 0 }
        let base = frames[way.base - 1].light
        let least = way.use.filter { $0 >= 1 && $0 <= frames.count }.map { frames[$0 - 1].light / base }.min() ?? 1
        return log2(1 / min(1, max(least, 1e-3)))
    }

    /// The frames as scripts see them, with what the merge `way` makes of each.
    public func json(with way: FrameMerge.Way) -> JSONValue {
        func rounded(_ value: Double, _ places: Double) -> JSONValue { .number((value * places).rounded() / places) }
        return .array(
            frames.enumerated().map { index, frame in
                [
                    "frame": .number(Double(index + 1)),
                    "time": .number(frame.time),
                    "iso": .number(frame.iso.rounded()),
                    "stops": rounded(log2(max(frame.light, 1e-6)), 100),
                    "after": rounded(frame.after, 100),
                    "sharpness": rounded(frame.sharpness, 100),
                    "blown": rounded(frame.blown, 1000),
                    "shift": rounded(frame.report.shift, 1),
                    "differs": rounded(frame.report.differs, 100),
                    "used": .bool(way.use.contains(index + 1)),
                    "base": .bool(way.base == index + 1),
                ]
            })
    }

    // MARK: At the camera

    /// How one frame was taken.
    public struct Shot: Sendable {
        public var time: Double
        public var iso: Double
        public var after: Double

        public init(time: Double, iso: Double, after: Double) {
            self.time = time
            self.iso = iso
            self.after = after
        }
    }

    /// What the camera makes of a shot's frames: the set, and its own merge of them, which is the
    /// photo's file. The base is the sharpest of the first three frames taken at the shot's own
    /// exposure (the first frame's); every frame is merged around it, movement frozen.
    public static func make(frames: [RawFrame], shots: [Shot]) throws -> (set: FrameSet, merged: MergedFrame) {
        guard let first = frames.first, frames.count == shots.count else { throw FrameMerging.Failure.noFrames }
        var described: [Frame] = []
        var detail: [Double] = []
        for (frame, shot) in zip(frames, shots) {
            let nominal = shots[0].time > 0 && shots[0].iso > 0 ? (shot.time * shot.iso) / (shots[0].time * shots[0].iso) : 1
            let light = described.isEmpty ? 1 : FrameMerging.light(of: frame, against: first, nominal: nominal > 0 ? nominal : 1)
            let blownLevel = UInt16(clamping: Int(frame.blownLevel))
            let blown = Double(frame.samples.reduce(0) { $0 + ($1 >= blownLevel ? 1 : 0) }) / Double(max(1, frame.samples.count))
            // Detail is measured in the frame's own numbers, which grow with its light.
            detail.append(BurstMerge.sharpness(of: frame) / (light * light))
            described.append(Frame(time: shot.time, iso: shot.iso, light: light, after: shot.after, blown: blown))
        }
        let sharpest = max(detail.max() ?? 1, 1e-9)
        for index in described.indices { described[index].sharpness = detail[index] / sharpest }
        let candidates = described.indices.prefix(3).filter { abs(log2(described[$0].light)) < 0.25 }
        let base = (candidates.max { detail[$0] < detail[$1] } ?? 0) + 1
        let way = FrameMerge.Way(base: base, use: Array(1...frames.count))
        var set = FrameSet(frames: described, merge: way)
        let result = try FrameMerging.merge(way, light: set.light) { frames[$0 - 1] }
        for (frame, report) in result.reports where frame >= 1 && frame <= described.count { set.frames[frame - 1].report = report }
        // The camera's own way keeps the sensor's grid: its merge is a mosaic.
        guard case .mosaic(let merged) = result.merged else { throw FrameMerging.Failure.sizes }
        return (set, merged)
    }
}
