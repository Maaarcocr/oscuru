import Dispatch
import Foundation

/// A merged picture: a mosaic like the sensor's, or (on a finer grid than the sensor's) all three
/// colours at every pixel; and how much brighter it is to be shown than its file says.
public enum MergedPicture: Sendable {
    case mosaic(MergedFrame)
    case rgb(RGBFrame, brightening: Double)

    public var brightening: Double {
        switch self {
        case .mosaic(let merged): return merged.brightening
        case .rgb(_, let brightening): return brightening
        }
    }
}

/// Merging a shot's frames one `FrameMerge.Way`: lined up as it says (`Motion`), each place
/// combined as it says, onto the grid it says.
public enum FrameMerging {
    public enum Failure: Error, Equatable {
        case noFrames
        /// The frames are not all one size.
        case sizes
    }

    public struct Result: Sendable {
        public var merged: MergedPicture
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
        if way.isSingle { return Result(merged: .mosaic(MergedFrame(frame: base, brightening: 0)), reports: [:]) }
        let others = way.use.filter { $0 != way.base }
        func share(_ frame: Int) -> Double { light[frame - 1] / light[way.base - 1] }
        func checked(_ frame: Int) throws -> RawFrame {
            let other = try load(frame)
            guard other.width == base.width, other.height == base.height, other.samples.count == base.samples.count, share(frame) > 0 else { throw Failure.sizes }
            return other
        }
        let grid = BurstMerge.tiles(width: base.width, height: base.height)
        let pyramid = Grey.pyramid(of: base)
        // The part of the grey picture whose movement is followed, in the sensor's own orientation.
        let followed = way.alignOn.map { rect -> (x: Double, y: Double, width: Double, height: Double) in
            let r = Orientation.toSensor(rect, orientation: base.orientation)
            return (r.x * Double(base.width / 2), r.y * Double(base.height / 2), r.width * Double(base.width / 2), r.height * Double(base.height / 2))
        }
        func motion(of other: RawFrame, light share: Double) -> (Motion, TileOffsets?) {
            if way.align == .none { return (.none, nil) }
            var offsets = Alignment.offsets(of: other, light: share, against: base, pyramid: pyramid, tilesAcross: grid.across, tilesDown: grid.down)
            // Onto a finer grid, each sample must land within a small fraction of a photosite of where it fell.
            if way.scale > 1 { offsets = Alignment.refined(offsets, of: other, light: share, against: base, camera: offsets.camera(within: followed)) }
            return way.align == .tiles ? (.tiles(offsets), offsets) : (.camera(offsets.camera(within: followed)), offsets)
        }

        var reports: [Int: FrameReport] = [:]
        if way.scale == 1, way.combine == .robust {
            // One frame at a time into the base, by tiles in the frequency domain (`BurstMerge`).
            var merge = BurstMerge(reference: base, tolerance: way.tolerance)
            for frame in others {
                let other = try checked(frame)
                let found = way.align == .tiles ? nil : TileOffsets(motion: motion(of: other, light: share(frame)).0, across: grid.across, down: grid.down)
                merge.add(other, light: share(frame), offsets: found)
                reports[frame] = merge.reports.last
            }
            return Result(merged: .mosaic(merge.merged()), reports: reports)
        }
        var stack: [Layer] = [Layer(frame: base, light: 1, motion: .none, shift: 0)]
        for frame in others {
            let other = try checked(frame)
            let (moved, offsets) = motion(of: other, light: share(frame))
            stack.append(Layer(frame: other, light: share(frame), motion: moved, shift: offsets?.shift ?? 0))
        }
        let merged: (picture: MergedPicture, differs: [Double])
        if way.scale == 1 {
            merged = PlaceMerge.merge(stack, combine: way.combine, tolerance: way.tolerance)
        } else {
            merged = GridMerge.merge(stack, combine: way.combine, scale: way.scale, tolerance: way.tolerance)
        }
        for (index, frame) in others.enumerated() {
            reports[frame] = FrameReport(shift: stack[index + 1].shift, differs: merged.differs[index + 1])
        }
        return Result(merged: merged.picture, reports: reports)
    }

    /// One frame of a merge: the frame, the light it took as a share of the base's, and where its
    /// picture lies against the base's. The base is the first, unmoved.
    struct Layer: Sendable {
        let frame: RawFrame
        let light: Double
        let motion: Motion
        /// How far the camera moved, in photosites: for the report.
        let shift: Double
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

/// From the frame as it stands upright to the sensor's own rows and columns, and back.
enum Orientation {
    /// A rectangle of the upright frame (fractions from its top-left) as one of the sensor's.
    static func toSensor(_ rect: FrameMerge.Rect, orientation: Int) -> FrameMerge.Rect {
        switch orientation {
        case 3: return FrameMerge.Rect(x: 1 - rect.x - rect.width, y: 1 - rect.y - rect.height, width: rect.width, height: rect.height)
        // The sensor's first row is the upright picture's right side, its first column the top.
        case 6: return FrameMerge.Rect(x: rect.y, y: 1 - rect.x - rect.width, width: rect.height, height: rect.width)
        // The sensor's first row is the upright picture's left side, its first column the bottom.
        case 8: return FrameMerge.Rect(x: 1 - rect.y - rect.height, y: rect.x, width: rect.height, height: rect.width)
        default: return rect
        }
    }
}

/// How each place is made from the values the frames have there, all at the base's brightness: the
/// one rule `PlaceMerge` and `GridMerge` share for every way of combining but the robust one
/// (`BurstMerge`, or `GridMerge`'s own on a finer grid).
struct Reducer {
    let combine: FrameMerge.Combine
    /// How far beyond noise a frame may be from the others and still count as agreeing with them,
    /// in variances.
    let agreement: Float

    init(combine: FrameMerge.Combine, tolerance: Float) {
        self.combine = combine
        agreement = 12 * tolerance / 8
    }

    /// The value from the frames' `values` (with each one's noise `variances`, the `light` each
    /// took as a share of the base's, whether each is `valid` (not blown) and, for the sharpest,
    /// how much detail each has there). Frames that differ from the result beyond noise are
    /// counted in `differs`. Nil when no frame is valid.
    func reduce(
        _ count: Int, values: UnsafePointer<Float>, variances: UnsafePointer<Float>, light: UnsafePointer<Float>, valid: UnsafePointer<Bool>,
        detail: UnsafePointer<Float>?, sorted: UnsafeMutablePointer<Float>, differs: UnsafeMutablePointer<Int>
    ) -> Float? {
        var held = 0
        for index in 0..<count where valid[index] {
            // Kept in order, smallest first.
            var at = held
            while at > 0, sorted[at - 1] > values[index] {
                sorted[at] = sorted[at - 1]
                at -= 1
            }
            sorted[at] = values[index]
            held += 1
        }
        guard held > 0 else { return nil }
        let middle = held % 2 == 1 ? sorted[held / 2] : (sorted[held / 2 - 1] + sorted[held / 2]) / 2
        var all: Float = 0
        var allCounted: Float = 0
        var still: Float = 0
        var stillCounted: Float = 0
        var brightest = -Float.infinity
        var brightestVariance: Float = 0
        var sharp: Float = 0
        var sharpCounted: Float = 0
        for index in 0..<count where valid[index] {
            let off = values[index] - middle
            all += light[index] * values[index]
            allCounted += light[index]
            if off * off <= agreement * variances[index] {
                still += light[index] * values[index]
                stillCounted += light[index]
            } else {
                differs[index] += 1
            }
            if values[index] > brightest {
                brightest = values[index]
                brightestVariance = variances[index]
            }
            if let detail {
                // The sharpest counts for far the most; frames about as sharp share the place, with no seam between them.
                let d = max(detail[index], 1e-6)
                let weight = light[index] * d * d * d * d
                sharp += weight * values[index]
                sharpCounted += weight
            }
        }
        let settled = stillCounted > 0 ? still / stillCounted : middle
        switch combine {
        case .mean, .robust: return all / allCounted
        case .median: return settled
        case .brightest:
            // Taken where it stands clear of the noise, and not at all where it does not.
            let deviation = max(brightestVariance, 1e-6).squareRoot()
            let clear = min(1, max(0, ((brightest - settled) / deviation - 4) / 4))
            return settled + clear * clear * (3 - 2 * clear) * (brightest - settled)
        case .sharpest: return sharpCounted > 0 ? sharp / sharpCounted : all / allCounted
        }
    }
}

/// How much fine detail a frame has around each place of its grey picture (at half its size):
/// what `sharpest` chooses by.
struct Detail: Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    /// `light` is the frame's light as a share of the base's: detail is measured at the base's brightness.
    init(of frame: RawFrame, light: Double) {
        let grey = Grey(of: frame)
        width = grey.width
        height = grey.height
        var energy = [Float](repeating: 0, count: width * height)
        let scale = Float(1 / max(light, 1e-6))
        let width = width
        let height = height
        grey.pixels.withUnsafeBufferPointer { greys in
            energy.withUnsafeMutableBufferPointer { energy in
                let out = UnsafeMutableSendable(energy.baseAddress!)
                let source = UnsafeSendable(greys.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: max(1, height - 2)) { index in
                    let y = index + 1
                    let pixels = source.pointer
                    for x in 1..<(width - 1) {
                        let here = Float(pixels[y * width + x])
                        let laplacian = 4 * here - Float(pixels[y * width + x - 1]) - Float(pixels[y * width + x + 1]) - Float(pixels[(y - 1) * width + x])
                            - Float(pixels[(y + 1) * width + x])
                        let scaled = laplacian * scale
                        out.pointer[y * width + x] = scaled * scaled
                    }
                }
            }
        }
        // Spread over its surroundings, so the choice follows what is in focus, not each grain.
        values = Detail.blurred(energy, width: width, height: height, radius: 4)
    }

    func at(_ x: Int, _ y: Int) -> Float { values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)] }

    static func blurred(_ input: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var across = [Float](repeating: 0, count: input.count)
        for y in 0..<height {
            var total: Float = 0
            for x in -radius...radius { total += input[y * width + min(max(x, 0), width - 1)] }
            for x in 0..<width {
                across[y * width + x] = total
                total += input[y * width + min(x + radius + 1, width - 1)] - input[y * width + max(x - radius, 0)]
            }
        }
        var down = [Float](repeating: 0, count: input.count)
        for x in 0..<width {
            var total: Float = 0
            for y in -radius...radius { total += across[min(max(y, 0), height - 1) * width + x] }
            for y in 0..<height {
                down[y * width + x] = total / Float((2 * radius + 1) * (2 * radius + 1))
                total += across[min(y + radius + 1, height - 1) * width + x] - across[max(y - radius, 0) * width + x]
            }
        }
        return down
    }
}

/// A pointer shared by work done at once on different parts of what it points to.
struct UnsafeMutableSendable<T>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<T>
    init(_ pointer: UnsafeMutablePointer<T>) { self.pointer = pointer }
}

struct UnsafeSendable<T>: @unchecked Sendable {
    let pointer: UnsafePointer<T>
    init(_ pointer: UnsafePointer<T>) { self.pointer = pointer }
}

/// Merging frames place by place on the sensor's own grid: every photosite of the picture is made
/// from the photosite each frame has at that place of the scene (moved by whole grey pixels, so
/// that each stays behind its own colour filter), combined as `Reducer` says.
enum PlaceMerge {
    static func merge(_ stack: [FrameMerging.Layer], combine: FrameMerge.Combine, tolerance: Float) -> (picture: MergedPicture, differs: [Double]) {
        let reference = stack[0].frame
        let width = reference.width
        let planeWidth = width / 2
        let planeHeight = reference.height / 2
        let count = stack.count
        let reducer = Reducer(combine: combine, tolerance: tolerance)
        let shares = stack.map { Float($0.light) }
        let blacks = stack.map { Float($0.frame.blackLevel) }
        let blown = stack.map { Float($0.frame.blownLevel) }
        let noises = stack.map { SensorNoise(of: $0.frame) }
        let black = blacks[0]
        let details = combine == .sharpest ? stack.map { Detail(of: $0.frame, light: $0.light) } : nil
        let motions = stack.map(\.motion)

        var out = [Float](repeating: 0, count: reference.samples.count)
        var differing = [Int](repeating: 0, count: count * planeHeight)
        withSamples(stack.map(\.frame)) { samples in
            out.withUnsafeMutableBufferPointer { out in
                differing.withUnsafeMutableBufferPointer { differing in
                    let target = UnsafeMutableSendable(out.baseAddress!)
                    let counts = UnsafeMutableSendable(differing.baseAddress!)
                    let sources = samples.map { UnsafeSendable($0) }
                    DispatchQueue.concurrentPerform(iterations: planeHeight) { py in
                        var values = [Float](repeating: 0, count: count)
                        var variances = [Float](repeating: 0, count: count)
                        var valid = [Bool](repeating: false, count: count)
                        var sorted = [Float](repeating: 0, count: count)
                        var detail = [Float](repeating: 0, count: count)
                        var differs = [Int](repeating: 0, count: count)
                        var places = [Int](repeating: 0, count: count)
                        var greys = [(Int, Int)](repeating: (0, 0), count: count)
                        for px in 0..<planeWidth {
                            // Where this place is in each frame: by whole grey pixels, so behind the same colour.
                            for index in 0..<count {
                                let move = motions[index].at(Double(px), Double(py))
                                let x = min(max(px + Int(move.x.rounded()), 0), planeWidth - 1)
                                let y = min(max(py + Int(move.y.rounded()), 0), planeHeight - 1)
                                places[index] = 2 * y * width + 2 * x
                                greys[index] = (x, y)
                                if let details { detail[index] = details[index].at(x, y) }
                            }
                            for colour in 0..<4 {
                                let within = (colour / 2) * width + colour % 2
                                for index in 0..<count {
                                    let taken = Float(sources[index].pointer[places[index] + within])
                                    valid[index] = taken < blown[index]
                                    // At the base's brightness.
                                    values[index] = black + (taken - blacks[index]) / shares[index]
                                    variances[index] = noises[index].variance(at: taken - blacks[index]) / (shares[index] * shares[index])
                                }
                                let place = 2 * py * width + 2 * px + within
                                let value = values.withUnsafeBufferPointer { values in
                                    variances.withUnsafeBufferPointer { variances in
                                        shares.withUnsafeBufferPointer { shares in
                                            valid.withUnsafeBufferPointer { valid in
                                                detail.withUnsafeBufferPointer { detail in
                                                    sorted.withUnsafeMutableBufferPointer { sorted in
                                                        differs.withUnsafeMutableBufferPointer { differs in
                                                            reducer.reduce(
                                                                count, values: values.baseAddress!, variances: variances.baseAddress!, light: shares.baseAddress!,
                                                                valid: valid.baseAddress!, detail: details == nil ? nil : detail.baseAddress!, sorted: sorted.baseAddress!,
                                                                differs: differs.baseAddress!)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                // Blown in every frame: as bright as anything can be.
                                target.pointer[place] = value ?? .infinity
                            }
                        }
                        for index in 0..<count { counts.pointer[py * count + index] = differs[index] }
                    }
                }
            }
        }
        let levels = MergedLevels(reference: reference, least: Double(shares.min() ?? 1), light: Double(shares.reduce(0, +)), frames: count)
        let factor = Float(levels.scale)
        let white = Float(levels.white)
        let samples = out.map { UInt16(max(0, min(white, ($0 * factor).rounded()))) }
        var differs: [Double] = []
        for index in 0..<count {
            var total = 0
            for row in 0..<planeHeight { total += differing[row * count + index] }
            differs.append(Double(total) / Double(max(1, reference.samples.count)))
        }
        return (.mosaic(levels.frame(samples)), differs)
    }

    /// Every frame's samples at once, for as long as `body` runs.
    static func withSamples(_ frames: [RawFrame], _ body: ([UnsafePointer<UInt16>]) -> Void) {
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
