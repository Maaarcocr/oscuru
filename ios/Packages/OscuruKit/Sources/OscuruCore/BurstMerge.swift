import Dispatch
import Foundation

/// Several raw frames of one scene, taken one after another at one exposure, made into one raw
/// frame with less noise: each frame is lined up with the first and averaged into it.
///
/// The way of Hasinoff and others ("Burst photography for high dynamic range and low-light imaging
/// on mobile cameras", 2016), working on the mosaic itself so the result is still a raw picture:
///
/// - Lining up. Each frame is reduced to grey at half size (one value per group of four
///   photosites) and compared with the first, tile by tile, from a coarse copy down to that grey.
///   A tile moves by whole grey pixels, so by two photosites: every sample stays behind its own
///   colour filter.
/// - Merging. Tile by tile and colour by colour, the difference between the first frame and the
///   lined-up one is taken apart by frequency. Where a frequency differs by no more than the
///   sensor's noise explains, the two are averaged; where it differs by more (something moved, or
///   detail that could not be lined up finer than two photosites), the first frame is kept. So
///   noise falls where the scene held still, and nothing ghosts or blurs where it did not.
///
/// Nothing else is done: no smoothing within a frame, no sharpening, no tone.
public struct BurstMerge {
    /// The frame the others are lined up with: the picture is its picture.
    public let reference: RawFrame
    /// How many frames are in the merge, the reference included.
    public private(set) var frames = 1

    /// Tiles are this many samples across in each colour, and overlap by half.
    static let tile = 16
    /// How far beyond the sensor's noise a difference may go and still be averaged: larger
    /// averages more and risks more.
    private let tolerance: Float

    private let planeWidth: Int
    private let planeHeight: Int
    /// The frames added up, laid out as the mosaic.
    private var sum: [Float]
    private let pyramid: [Grey]
    /// The sensor's noise at a sample value: `perSignal` times the value above black, plus `floor`.
    private let noise: (perSignal: Float, floor: Float)
    private let black: Float

    public init(reference: RawFrame, tolerance: Float = 8) {
        self.tolerance = tolerance
        precondition(reference.width % 2 == 0 && reference.height % 2 == 0 && reference.samples.count == reference.width * reference.height)
        self.reference = reference
        planeWidth = reference.width / 2
        planeHeight = reference.height / 2
        sum = reference.samples.map(Float.init)
        pyramid = Grey.pyramid(of: reference)
        black = Float(reference.blackLevel)
        let range = max(1, reference.whiteLevel - reference.blackLevel)
        if reference.noiseProfile.count >= 2, reference.noiseProfile[0] >= 0, reference.noiseProfile[1] >= 0, reference.noiseProfile[0] + reference.noiseProfile[1] > 0 {
            noise = (Float(reference.noiseProfile[0] * range), Float(reference.noiseProfile[1] * range * range))
        } else {
            noise = (0, Self.measuredNoise(of: reference))
        }
    }

    /// How much fine detail a frame holds: the sharpest of a few frames makes the best reference.
    public static func sharpness(of frame: RawFrame) -> Double {
        let grey = Grey(of: frame).reduced(by: 2)
        guard grey.width > 2, grey.height > 2 else { return 0 }
        var total = 0.0
        grey.pixels.withUnsafeBufferPointer { pixels in
            for y in 1..<grey.height {
                for x in 1..<grey.width {
                    let here = Double(pixels[y * grey.width + x])
                    let across = here - Double(pixels[y * grey.width + x - 1])
                    let down = here - Double(pixels[(y - 1) * grey.width + x])
                    total += across * across + down * down
                }
            }
        }
        return total / Double(grey.width * grey.height)
    }

    /// Lines a frame up with the reference and adds it in. It must be the reference's size.
    public mutating func add(_ frame: RawFrame) {
        guard frame.width == reference.width, frame.height == reference.height, frame.samples.count == reference.samples.count else { return }
        let offsets = align(frame)
        merge(frame, offsets: offsets)
        frames += 1
    }

    /// The merged picture. Its samples and levels are the reference's multiplied by a power of
    /// two, as large as sixteen bits allow, so the precision the averaging earned is kept; its
    /// noise model is the reference's divided by the number of frames.
    public func merged() -> RawFrame {
        var scale = 1
        while Double(scale * 2) * reference.whiteLevel <= 65535, scale < 256 { scale *= 2 }
        let factor = Float(scale) / Float(frames)
        var samples = [UInt16](repeating: 0, count: sum.count)
        sum.withUnsafeBufferPointer { sum in
            samples.withUnsafeMutableBufferPointer { samples in
                for index in 0..<sum.count { samples[index] = UInt16(max(0, min(65535, (sum[index] * factor).rounded()))) }
            }
        }
        return RawFrame(
            width: reference.width, height: reference.height, samples: samples, blackLevels: reference.blackLevels.map { $0 * Double(scale) },
            whiteLevel: reference.whiteLevel * Double(scale), noiseProfile: reference.noiseProfile.map { $0 / Double(frames) })
    }

    // MARK: Lining up

    /// How far each fine tile of a frame has moved against the reference, in grey pixels.
    private struct Offsets: Sendable {
        var across: Int
        var down: Int
        var x: [Int16]
        var y: [Int16]
    }

    /// The fine tiles: `tile` wide, half a tile apart, starting half a tile outside the picture so
    /// that every sample lies in two tiles each way.
    private var tilesAcross: Int { (planeWidth + Self.tile / 2 - 1) / (Self.tile / 2) + 1 }
    private var tilesDown: Int { (planeHeight + Self.tile / 2 - 1) / (Self.tile / 2) + 1 }

    private func align(_ frame: RawFrame) -> Offsets {
        let other = Grey.pyramid(of: frame)
        // From the coarsest copy to the finest, each starting from what the coarser one found.
        var coarse: Offsets?
        var coarseTile = 0
        for level in stride(from: pyramid.count - 1, through: 0, by: -1) {
            let ours = pyramid[level]
            let theirs = other[level]
            let finest = level == 0
            let size = min(Self.tile, max(4, min(ours.width, ours.height)))
            let step = finest ? Self.tile / 2 : size
            let start = finest ? -Self.tile / 2 : 0
            let across = finest ? tilesAcross : (ours.width + size - 1) / size
            let down = finest ? tilesDown : (ours.height + size - 1) / size
            // A coarser copy has already found the tile to within a pixel of its own, which is
            // `scale` here: only that much is searched again. The coarsest searches furthest.
            let scale = level + 1 < pyramid.count ? Grey.factors[level + 1] : 1
            let radius = coarse == nil ? 4 : (finest ? 1 : scale)
            var foundX = [Int16](repeating: 0, count: across * down)
            var foundY = [Int16](repeating: 0, count: across * down)
            let before = coarse
            let beforeTile = coarseTile
            ours.pixels.withUnsafeBufferPointer { reference in
                theirs.pixels.withUnsafeBufferPointer { moved in
                    foundX.withUnsafeMutableBufferPointer { foundX in
                        foundY.withUnsafeMutableBufferPointer { foundY in
                            let out = Found(x: foundX.baseAddress!, y: foundY.baseAddress!)
                            let search = Search(reference: reference.baseAddress!, moved: moved.baseAddress!, width: ours.width, height: ours.height, size: size)
                            DispatchQueue.concurrentPerform(iterations: down) { row in
                                for column in 0..<across {
                                    let x0 = start + column * step
                                    let y0 = start + row * step
                                    var best = (x: 0, y: 0)
                                    if let before {
                                        // The coarser tile this one lies in, and its neighbours towards this tile's side of it.
                                        let centreX = (x0 + size / 2) / scale
                                        let centreY = (y0 + size / 2) / scale
                                        let tileX = min(max(centreX / beforeTile, 0), before.across - 1)
                                        let tileY = min(max(centreY / beforeTile, 0), before.down - 1)
                                        let sideX = min(max(tileX + (centreX % beforeTile < beforeTile / 2 ? -1 : 1), 0), before.across - 1)
                                        let sideY = min(max(tileY + (centreY % beforeTile < beforeTile / 2 ? -1 : 1), 0), before.down - 1)
                                        var least = Int.max
                                        for (candidateX, candidateY) in [(tileX, tileY), (sideX, tileY), (tileX, sideY)] {
                                            let index = candidateY * before.across + candidateX
                                            let candidate = (x: Int(before.x[index]) * scale, y: Int(before.y[index]) * scale)
                                            let difference = search.difference(x0: x0, y0: y0, dx: candidate.x, dy: candidate.y, limit: least)
                                            if difference < least {
                                                least = difference
                                                best = candidate
                                            }
                                        }
                                    }
                                    best = search.best(x0: x0, y0: y0, around: best, radius: radius)
                                    out.x[row * across + column] = Int16(clamping: best.x)
                                    out.y[row * across + column] = Int16(clamping: best.y)
                                }
                            }
                        }
                    }
                }
            }
            coarse = Offsets(across: across, down: down, x: foundX, y: foundY)
            coarseTile = size
        }
        return coarse ?? Offsets(across: tilesAcross, down: tilesDown, x: [Int16](repeating: 0, count: tilesAcross * tilesDown), y: [Int16](repeating: 0, count: tilesAcross * tilesDown))
    }

    /// Where a level's answers are written, by rows of tiles worked on at once (each its own row).
    private struct Found: @unchecked Sendable {
        let x: UnsafeMutablePointer<Int16>
        let y: UnsafeMutablePointer<Int16>
    }

    /// Comparing one tile of the reference with the same tile of another frame, moved.
    private struct Search: @unchecked Sendable {
        let reference: UnsafePointer<UInt16>
        let moved: UnsafePointer<UInt16>
        let width: Int
        let height: Int
        let size: Int

        /// The sum of squared differences, given up on once it passes `limit`.
        func difference(x0: Int, y0: Int, dx: Int, dy: Int, limit: Int) -> Int {
            var total = 0
            let inside = x0 >= 0 && y0 >= 0 && x0 + size <= width && y0 + size <= height && x0 + dx >= 0 && y0 + dy >= 0 && x0 + dx + size <= width && y0 + dy + size <= height
            if inside {
                for y in 0..<size {
                    let ours = reference + (y0 + y) * width + x0
                    let theirs = moved + (y0 + dy + y) * width + x0 + dx
                    for x in 0..<size {
                        let difference = Int(ours[x]) - Int(theirs[x])
                        total += difference * difference
                    }
                    if total >= limit { return total }
                }
                return total
            }
            // At the picture's edge, what lies outside is what lies at the edge.
            for y in 0..<size {
                let ourRow = min(max(y0 + y, 0), height - 1) * width
                let theirRow = min(max(y0 + dy + y, 0), height - 1) * width
                for x in 0..<size {
                    let difference = Int(reference[ourRow + min(max(x0 + x, 0), width - 1)]) - Int(moved[theirRow + min(max(x0 + dx + x, 0), width - 1)])
                    total += difference * difference
                }
                if total >= limit { return total }
            }
            return total
        }

        /// The move within `radius` of `around` at which the tiles differ least; of equals, the nearest to it.
        func best(x0: Int, y0: Int, around: (x: Int, y: Int), radius: Int) -> (x: Int, y: Int) {
            var best = around
            var least = difference(x0: x0, y0: y0, dx: around.x, dy: around.y, limit: Int.max)
            for dy in -radius...radius {
                for dx in -radius...radius where dx != 0 || dy != 0 {
                    let found = difference(x0: x0, y0: y0, dx: around.x + dx, dy: around.y + dy, limit: least)
                    if found < least {
                        least = found
                        best = (around.x + dx, around.y + dy)
                    }
                }
            }
            return best
        }
    }

    // MARK: Merging

    private mutating func merge(_ frame: RawFrame, offsets: Offsets) {
        let size = Self.tile
        let width = reference.width
        let planeWidth = planeWidth
        let planeHeight = planeHeight
        let noise = noise
        let black = black
        let tolerance = tolerance
        // A tile fades in and out over its half-overlap so that tiles add up to one everywhere.
        let window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(size))) }
        let fourier = Fourier()
        reference.samples.withUnsafeBufferPointer { ours in
            frame.samples.withUnsafeBufferPointer { theirs in
                sum.withUnsafeMutableBufferPointer { sum in
                    offsets.x.withUnsafeBufferPointer { offsetsX in
                        offsets.y.withUnsafeBufferPointer { offsetsY in
                            window.withUnsafeBufferPointer { window in
                                let work = Work(
                                    ours: ours.baseAddress!, theirs: theirs.baseAddress!, sum: sum.baseAddress!, offsetsX: offsetsX.baseAddress!,
                                    offsetsY: offsetsY.baseAddress!, window: window.baseAddress!)
                                // Rows of tiles two apart share no samples, so they can be worked on at once.
                                for parity in 0..<2 {
                                    let rows = (offsets.down - parity + 1) / 2
                                    DispatchQueue.concurrentPerform(iterations: rows) { index in
                                        let row = index * 2 + parity
                                        var real = [Float](repeating: 0, count: size * size)
                                        var imaginary = [Float](repeating: 0, count: size * size)
                                        var moved = [Float](repeating: 0, count: size * size)
                                        real.withUnsafeMutableBufferPointer { real in
                                            imaginary.withUnsafeMutableBufferPointer { imaginary in
                                                moved.withUnsafeMutableBufferPointer { moved in
                                                    let real = real.baseAddress!
                                                    let imaginary = imaginary.baseAddress!
                                                    let moved = moved.baseAddress!
                                                    for column in 0..<offsets.across {
                                                        let x0 = column * (size / 2) - size / 2
                                                        let y0 = row * (size / 2) - size / 2
                                                        let dx = Int(work.offsetsX[row * offsets.across + column])
                                                        let dy = Int(work.offsetsY[row * offsets.across + column])
                                                        // Each of the four colours of the pattern on its own.
                                                        for colour in 0..<4 {
                                                            let cx = colour % 2
                                                            let cy = colour / 2
                                                            var total: Float = 0
                                                            for y in 0..<size {
                                                                let ourRow = (2 * min(max(y0 + y, 0), planeHeight - 1) + cy) * width + cx
                                                                let theirRow = (2 * min(max(y0 + dy + y, 0), planeHeight - 1) + cy) * width + cx
                                                                for x in 0..<size {
                                                                    let first = Float(work.ours[ourRow + 2 * min(max(x0 + x, 0), planeWidth - 1)])
                                                                    let other = Float(work.theirs[theirRow + 2 * min(max(x0 + dx + x, 0), planeWidth - 1)])
                                                                    moved[y * size + x] = other
                                                                    real[y * size + x] = first - other
                                                                    imaginary[y * size + x] = 0
                                                                    total += first
                                                                }
                                                            }
                                                            // What the sensor's noise alone would make of a difference at this brightness.
                                                            let level = max(0, total / Float(size * size) - black)
                                                            let variance = max(noise.perSignal * level + noise.floor, 1e-3)
                                                            let allowed = tolerance * 2 * Float(size * size) * variance
                                                            fourier.forward(real, imaginary)
                                                            for bin in 0..<(size * size) {
                                                                let power = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                                                                // Near 0 where the difference is noise (the other frame is taken),
                                                                // near 1 where it is more (the first frame is kept).
                                                                let keep = power / (power + allowed)
                                                                real[bin] *= keep
                                                                imaginary[bin] *= keep
                                                            }
                                                            fourier.inverse(real, imaginary)
                                                            for y in 0..<size where y0 + y >= 0 && y0 + y < planeHeight {
                                                                let outRow = (2 * (y0 + y) + cy) * width + cx
                                                                for x in 0..<size where x0 + x >= 0 && x0 + x < planeWidth {
                                                                    work.sum[outRow + 2 * (x0 + x)] += work.window[x] * work.window[y] * (moved[y * size + x] + real[y * size + x])
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The pointers a merge works through, shared by the rows of tiles worked on at once (which
    /// write to different samples).
    private struct Work: @unchecked Sendable {
        let ours: UnsafePointer<UInt16>
        let theirs: UnsafePointer<UInt16>
        let sum: UnsafeMutablePointer<Float>
        let offsetsX: UnsafePointer<Int16>
        let offsetsY: UnsafePointer<Int16>
        let window: UnsafePointer<Float>
    }

    /// A frame's noise measured from the frame itself, for a file that does not say: the variance
    /// of what is left of one colour when everything smooth is taken away (Immerkær's estimate).
    private static func measuredNoise(of frame: RawFrame) -> Float {
        let width = frame.width / 2
        let height = frame.height / 2
        guard width > 2, height > 2 else { return 1 }
        var total = 0.0
        var count = 0.0
        frame.samples.withUnsafeBufferPointer { samples in
            func at(_ x: Int, _ y: Int) -> Double { Double(samples[2 * y * frame.width + 2 * x]) }
            for y in stride(from: 1, to: height - 1, by: 2) {
                for x in stride(from: 1, to: width - 1, by: 2) {
                    let left = at(x - 1, y - 1) - 2 * at(x, y - 1) + at(x + 1, y - 1)
                    let middle = -2 * at(x - 1, y) + 4 * at(x, y) - 2 * at(x + 1, y)
                    let right = at(x - 1, y + 1) - 2 * at(x, y + 1) + at(x + 1, y + 1)
                    total += abs(left + middle + right)
                    count += 1
                }
            }
        }
        let sigma = (Double.pi / 2).squareRoot() / 6 * total / max(1, count)
        return Float(max(sigma * sigma, 0.25))
    }
}

/// A frame as greys at half its size, one for every group of four photosites, and smaller copies
/// of that: what frames are lined up by.
private struct Grey {
    var width: Int
    var height: Int
    var pixels: [UInt16]

    /// How much smaller each copy is than the one before it: the half-size grey, then a half, then quarters.
    static let factors = [1, 2, 4, 4]

    init(width: Int, height: Int, pixels: [UInt16]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(of frame: RawFrame) {
        width = frame.width / 2
        height = frame.height / 2
        pixels = [UInt16](repeating: 0, count: width * height)
        let width = width
        let height = height
        frame.samples.withUnsafeBufferPointer { samples in
            pixels.withUnsafeMutableBufferPointer { pixels in
                for y in 0..<height {
                    let top = 2 * y * frame.width
                    let bottom = top + frame.width
                    for x in 0..<width {
                        let total = Int(samples[top + 2 * x]) + Int(samples[top + 2 * x + 1]) + Int(samples[bottom + 2 * x]) + Int(samples[bottom + 2 * x + 1])
                        pixels[y * width + x] = UInt16(total / 4)
                    }
                }
            }
        }
    }

    /// This picture `factor` times smaller, each pixel the average of the ones it covers.
    func reduced(by factor: Int) -> Grey {
        let smallWidth = width / factor
        let smallHeight = height / factor
        var small = [UInt16](repeating: 0, count: smallWidth * smallHeight)
        pixels.withUnsafeBufferPointer { pixels in
            small.withUnsafeMutableBufferPointer { small in
                for y in 0..<smallHeight {
                    for x in 0..<smallWidth {
                        var total = 0
                        for dy in 0..<factor {
                            let row = (y * factor + dy) * width + x * factor
                            for dx in 0..<factor { total += Int(pixels[row + dx]) }
                        }
                        small[y * smallWidth + x] = UInt16(total / (factor * factor))
                    }
                }
            }
        }
        return Grey(width: smallWidth, height: smallHeight, pixels: small)
    }

    /// The grey and its smaller copies, largest first, for as long as a copy is big enough to compare tiles in.
    static func pyramid(of frame: RawFrame) -> [Grey] {
        var levels = [Grey(of: frame)]
        for factor in factors.dropFirst() {
            guard let last = levels.last, last.width / factor >= 16, last.height / factor >= 16 else { break }
            levels.append(last.reduced(by: factor))
        }
        return levels
    }
}

/// The two-dimensional Fourier transform of a tile, sixteen samples each way, in place.
private struct Fourier: Sendable {
    private let cosines: [Float]
    private let sines: [Float]
    private static let size = BurstMerge.tile
    private static let reversed = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]

    init() {
        cosines = (0..<(Self.size / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(Self.size))) }
        sines = (0..<(Self.size / 2)).map { Float(sin(2 * Double.pi * Double($0) / Double(Self.size))) }
    }

    func forward(_ real: UnsafeMutablePointer<Float>, _ imaginary: UnsafeMutablePointer<Float>) {
        transform(real, imaginary, sign: -1)
    }

    /// The inverse, scaled so that forward and then inverse gives back what went in.
    func inverse(_ real: UnsafeMutablePointer<Float>, _ imaginary: UnsafeMutablePointer<Float>) {
        transform(real, imaginary, sign: 1)
        let scale = 1 / Float(Self.size * Self.size)
        for index in 0..<(Self.size * Self.size) {
            real[index] *= scale
            imaginary[index] *= scale
        }
    }

    private func transform(_ real: UnsafeMutablePointer<Float>, _ imaginary: UnsafeMutablePointer<Float>, sign: Float) {
        for row in 0..<Self.size { line(real + row * Self.size, imaginary + row * Self.size, step: 1, sign: sign) }
        for column in 0..<Self.size { line(real + column, imaginary + column, step: Self.size, sign: sign) }
    }

    /// One row or column: the usual radix-2 transform of sixteen values `step` apart.
    private func line(_ real: UnsafeMutablePointer<Float>, _ imaginary: UnsafeMutablePointer<Float>, step: Int, sign: Float) {
        let size = Self.size
        for index in 0..<size {
            let other = Self.reversed[index]
            if other > index {
                let a = real[index * step]
                real[index * step] = real[other * step]
                real[other * step] = a
                let b = imaginary[index * step]
                imaginary[index * step] = imaginary[other * step]
                imaginary[other * step] = b
            }
        }
        var half = 1
        while half < size {
            let stride = size / (2 * half)
            var start = 0
            while start < size {
                for k in 0..<half {
                    let cosine = cosines[k * stride]
                    let sine = sign * sines[k * stride]
                    let upper = (start + k) * step
                    let lower = (start + k + half) * step
                    let re = real[lower] * cosine - imaginary[lower] * sine
                    let im = real[lower] * sine + imaginary[lower] * cosine
                    real[lower] = real[upper] - re
                    imaginary[lower] = imaginary[upper] - im
                    real[upper] += re
                    imaginary[upper] += im
                }
                start += 2 * half
            }
            half *= 2
        }
    }
}
