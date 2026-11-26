import Dispatch
import Foundation

/// Merging a shot's frames one `FrameMerge.Way`.
public enum FrameMerging {
    public enum Failure: Error, Equatable {
        case noFrames
        /// The frames are not all one size.
        case sizes
    }

    public struct Result: Sendable {
        public var merged: MergedFrame
        /// What lining up and merging found of each frame used, by its number; the base is not among them.
        public var reports: [Int: FrameReport]
    }

    /// The merge of the frames `way` names. `light` is each frame's light as a share of the first
    /// frame's, in order; `load` gives a frame by its number, and is asked for one at a time where
    /// the way of merging allows, so that not all of them need be in memory at once.
    public static func merge(_ way: FrameMerge.Way, light: [Double], load: (Int) throws -> RawFrame) throws -> Result {
        guard way.base >= 1, way.base <= light.count, way.use.allSatisfy({ $0 >= 1 && $0 <= light.count }), light[way.base - 1] > 0 else { throw Failure.noFrames }
        let base = try load(way.base)
        guard base.width % 2 == 0, base.height % 2 == 0, base.samples.count == base.width * base.height, base.width >= 32, base.height >= 32 else { throw Failure.sizes }
        if way.isSingle { return Result(merged: MergedFrame(frame: base, brightening: 0), reports: [:]) }
        let others = way.use.filter { $0 != way.base }
        func share(_ frame: Int) -> Double { light[frame - 1] / light[way.base - 1] }
        var reports: [Int: FrameReport] = [:]
        if way.movement == .freeze {
            var merge = BurstMerge(reference: base, tolerance: way.tolerance)
            for frame in others {
                let other = try load(frame)
                guard other.width == base.width, other.height == base.height, other.samples.count == base.samples.count, share(frame) > 0 else { throw Failure.sizes }
                merge.add(other, light: share(frame))
                reports[frame] = merge.reports.last
            }
            return Result(merged: merge.merged(), reports: reports)
        }
        var stack: [(frame: RawFrame, light: Double)] = []
        for frame in others {
            let other = try load(frame)
            guard other.width == base.width, other.height == base.height, other.samples.count == base.samples.count, share(frame) > 0 else { throw Failure.sizes }
            stack.append((other, share(frame)))
        }
        let merged = StackMerge.merge(reference: base, others: stack, movement: way.movement)
        for (frame, report) in zip(others, merged.reports) { reports[frame] = report }
        return Result(merged: merged.merged, reports: reports)
    }

    /// The light a frame took as a share of another's, measured from the two: the ratio of their
    /// greys where both hold something and neither is near blown. `nominal` is what their
    /// exposures say, and stands where the frames do not say otherwise (too little to measure,
    /// or a measure far from it, as when the scene changed between them).
    static func light(of frame: RawFrame, against first: RawFrame, nominal: Double) -> Double {
        guard frame.width == first.width, frame.height == first.height else { return nominal }
        let ours = Grey(of: first).reduced(by: 4)
        let theirs = Grey(of: frame).reduced(by: 4)
        let ourBlack = first.blackLevel
        let theirBlack = frame.blackLevel
        let ourRange = first.whiteLevel - ourBlack
        let theirRange = frame.whiteLevel - theirBlack
        var ourTotal = 0.0
        var theirTotal = 0.0
        var count = 0
        for index in 0..<min(ours.pixels.count, theirs.pixels.count) {
            let a = Double(ours.pixels[index]) - ourBlack
            let b = Double(theirs.pixels[index]) - theirBlack
            guard a >= 0.02 * ourRange, b >= 0.02 * theirRange, a <= 0.5 * ourRange, b <= 0.5 * theirRange else { continue }
            ourTotal += a
            theirTotal += b
            count += 1
        }
        guard count >= 200, ourTotal > 0 else { return nominal }
        let measured = theirTotal / ourTotal
        return measured > nominal / 1.5 && measured < nominal * 1.5 ? measured : nominal
    }
}

/// Merging frames place by place, for the ways that do something with movement: each frame is
/// lined up as a whole (by the camera's own movement between the frames, so that what moved in
/// the scene stays where it was in each), and every photosite of the picture is made from that
/// photosite in all of them.
enum StackMerge {
    static func merge(reference: RawFrame, others: [(frame: RawFrame, light: Double)], movement: FrameMerge.Movement) -> (merged: MergedFrame, reports: [FrameReport]) {
        let width = reference.width
        let planeWidth = reference.width / 2
        let planeHeight = reference.height / 2
        let half = BurstMerge.tile / 2
        let tilesAcross = (planeWidth + half - 1) / half + 1
        let tilesDown = (planeHeight + half - 1) / half + 1
        let pyramid = Grey.pyramid(of: reference)
        let found = others.map { other in
            Alignment.offsets(of: other.frame, light: other.light, against: reference, pyramid: pyramid, tilesAcross: tilesAcross, tilesDown: tilesDown)
        }
        let shifts = found.map(\.shift)
        let moves = [CameraMove()] + found.map { $0.camera() }
        let frames = [reference] + others.map(\.frame)
        let count = frames.count
        let shares = [Float(1)] + others.map { Float($0.light) }
        let blacks = frames.map { Float($0.blackLevel) }
        let blown = frames.map { Float($0.blownLevel) }
        let noises = frames.map { SensorNoise(of: $0) }
        let black = blacks[0]

        var out = [Float](repeating: 0, count: reference.samples.count)
        // Places where each frame differs from the picture by more than noise, by row.
        var differing = [Int](repeating: 0, count: count * planeHeight)
        withPointers(frames) { samples in
            out.withUnsafeMutableBufferPointer { out in
                differing.withUnsafeMutableBufferPointer { differing in
                    let work = Work(samples: samples, out: out.baseAddress!, differing: differing.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: planeHeight) { py in
                        var values = [Float](repeating: 0, count: count)
                        var variances = [Float](repeating: 0, count: count)
                        var valid = [Bool](repeating: false, count: count)
                        var sorted = [Float](repeating: 0, count: count)
                        var places = [Int](repeating: 0, count: count)
                        var differs = [Int](repeating: 0, count: count)
                        for px in 0..<planeWidth {
                            // Where this place is in each frame: by whole grey pixels, so behind the same colour.
                            for index in 0..<count {
                                let move = index == 0 ? (x: 0.0, y: 0.0) : moves[index].at(Double(px), Double(py))
                                let x = min(max(px + Int(move.x.rounded()), 0), planeWidth - 1)
                                let y = min(max(py + Int(move.y.rounded()), 0), planeHeight - 1)
                                places[index] = 2 * y * width + 2 * x
                            }
                            for colour in 0..<4 {
                                let within = (colour / 2) * width + colour % 2
                                var held = 0
                                for index in 0..<count {
                                    let taken = Float(work.samples[index][places[index] + within])
                                    let share = shares[index]
                                    valid[index] = taken < blown[index]
                                    // At the reference's brightness.
                                    values[index] = black + (taken - blacks[index]) / share
                                    variances[index] = noises[index].variance(at: taken - blacks[index]) / (share * share)
                                    if valid[index] {
                                        // Kept in order, smallest first.
                                        var at = held
                                        while at > 0, sorted[at - 1] > values[index] {
                                            sorted[at] = sorted[at - 1]
                                            at -= 1
                                        }
                                        sorted[at] = values[index]
                                        held += 1
                                    }
                                }
                                let place = 2 * py * width + 2 * px + within
                                guard held > 0 else {
                                    // Blown in every frame.
                                    work.out[place] = .infinity
                                    continue
                                }
                                let middle = held % 2 == 1 ? sorted[held / 2] : (sorted[held / 2 - 1] + sorted[held / 2]) / 2
                                var all: Float = 0
                                var allCounted: Float = 0
                                var still: Float = 0
                                var stillCounted: Float = 0
                                var brightest = -Float.infinity
                                var brightestVariance: Float = 0
                                for index in 0..<count where valid[index] {
                                    let off = values[index] - middle
                                    all += shares[index] * values[index]
                                    allCounted += shares[index]
                                    if off * off <= 12 * variances[index] {
                                        still += shares[index] * values[index]
                                        stillCounted += shares[index]
                                    } else {
                                        differs[index] += 1
                                    }
                                    if values[index] > brightest {
                                        brightest = values[index]
                                        brightestVariance = variances[index]
                                    }
                                }
                                let settled = stillCounted > 0 ? still / stillCounted : middle
                                switch movement {
                                case .blur, .freeze:
                                    work.out[place] = all / allCounted
                                case .remove:
                                    work.out[place] = settled
                                case .trails:
                                    // Taken where it stands clear of the noise, and not at all where it does not.
                                    let deviation = brightestVariance.squareRoot()
                                    let clear = min(1, max(0, ((brightest - settled) / deviation - 4) / 4))
                                    work.out[place] = settled + clear * clear * (3 - 2 * clear) * (brightest - settled)
                                }
                            }
                        }
                        for index in 0..<count { work.differing[py * count + index] = differs[index] }
                    }
                }
            }
        }

        let levels = MergedLevels(reference: reference, least: Double(shares.min() ?? 1), light: Double(shares.reduce(0, +)), frames: count)
        let factor = Float(levels.scale)
        let white = Float(levels.white)
        let samples = out.map { UInt16(max(0, min(white, ($0 * factor).rounded()))) }
        var reports: [FrameReport] = []
        for index in 1..<max(count, 1) {
            var total = 0
            for row in 0..<planeHeight { total += differing[row * count + index] }
            reports.append(FrameReport(shift: shifts[index - 1], differs: Double(total) / Double(max(1, reference.samples.count))))
        }
        return (levels.frame(samples), reports)
    }

    private struct Work: @unchecked Sendable {
        let samples: [UnsafePointer<UInt16>]
        let out: UnsafeMutablePointer<Float>
        let differing: UnsafeMutablePointer<Int>
    }

    /// Every frame's samples at once, for as long as `body` runs.
    private static func withPointers(_ frames: [RawFrame], _ body: ([UnsafePointer<UInt16>]) -> Void) {
        var pointers: [UnsafePointer<UInt16>] = []
        func next(_ index: Int) {
            if index == frames.count {
                body(pointers)
                return
            }
            frames[index].samples.withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                next(index + 1)
            }
        }
        next(0)
    }
}
