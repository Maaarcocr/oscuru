import Dispatch
import Foundation

/// Several raw frames of one scene, taken one after another, made into one raw frame with less
/// noise: each frame is lined up with the first and averaged into it. The frames may differ in
/// exposure (a bracket): each is first brought to the first frame's brightness, counts for as much
/// as the light it took, and gives nothing where it is blown; where the first frame is blown, the
/// picture is what the darker frames recorded there, brighter than the first frame's white.
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
    /// What lining up and merging each added frame found, in the order added.
    public private(set) var reports: [FrameReport] = []

    /// Tiles are this many samples across in each colour, and overlap by half.
    static let tile = 16
    /// How far beyond the sensor's noise a difference may go and still be averaged: larger
    /// averages more and risks more.
    private let tolerance: Float

    private let planeWidth: Int
    private let planeHeight: Int
    /// The frames added up, each sample times what it counts for, laid out as the mosaic; and
    /// what the samples added at each place counted for in all.
    private var sum: [Float]
    private var weight: [Float]
    private let pyramid: [Grey]
    private let noise: SensorNoise
    private let black: Float
    /// The light of the dimmest frame in the merge, and of all of them together, as shares of the reference's.
    private var least = 1.0
    private var light = 1.0

    /// What a blown sample of the reference counts for: next to nothing, so that any frame that
    /// recorded the place decides it, and the reference still does where none did.
    static let blownWeight: Float = 1e-3

    public init(reference: RawFrame, tolerance: Float = 8) {
        self.tolerance = tolerance
        precondition(reference.width % 2 == 0 && reference.height % 2 == 0 && reference.samples.count == reference.width * reference.height)
        self.reference = reference
        planeWidth = reference.width / 2
        planeHeight = reference.height / 2
        let blown = UInt16(clamping: Int(reference.blownLevel))
        weight = reference.samples.map { $0 >= blown ? Self.blownWeight : 1 }
        sum = zip(reference.samples, weight).map { Float($0) * $1 }
        pyramid = Grey.pyramid(of: reference)
        black = Float(reference.blackLevel)
        noise = SensorNoise(of: reference)
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
    /// `light` is how much light it took, as a share of the reference's (1 for the same exposure).
    public mutating func add(_ frame: RawFrame, light share: Double = 1) {
        guard frame.width == reference.width, frame.height == reference.height, frame.samples.count == reference.samples.count, share > 0 else { return }
        let offsets = Alignment.offsets(of: frame, light: share, against: reference, pyramid: pyramid, tilesAcross: tilesAcross, tilesDown: tilesDown)
        let differs = merge(frame, light: Float(share), offsets: offsets)
        frames += 1
        least = min(least, share)
        light += share
        reports.append(FrameReport(shift: offsets.shift, differs: differs))
    }

    /// The merged picture and how much brighter it is to be shown (see `MergedFrame`).
    public func merged() -> MergedFrame {
        let levels = MergedLevels(reference: reference, least: least, light: light, frames: frames)
        var samples = [UInt16](repeating: 0, count: sum.count)
        let factor = Float(levels.scale)
        let white = Float(levels.white)
        let untouched = Self.blownWeight * 1.5
        sum.withUnsafeBufferPointer { sum in
            weight.withUnsafeBufferPointer { weight in
                samples.withUnsafeMutableBufferPointer { samples in
                    for index in 0..<sum.count {
                        // Blown in every frame: white, whatever the brightest of them could hold.
                        let value = weight[index] <= untouched ? white : sum[index] / weight[index] * factor
                        samples[index] = UInt16(max(0, min(white, value.rounded())))
                    }
                }
            }
        }
        return levels.frame(samples)
    }

    /// The fine tiles: `tile` wide, half a tile apart, starting half a tile outside the picture so
    /// that every sample lies in two tiles each way.
    private var tilesAcross: Int { (planeWidth + Self.tile / 2 - 1) / (Self.tile / 2) + 1 }
    private var tilesDown: Int { (planeHeight + Self.tile / 2 - 1) / (Self.tile / 2) + 1 }

    // MARK: Merging

    /// Adds a lined-up frame in, and returns the share of the picture where it differs from the
    /// reference by more than noise.
    private mutating func merge(_ frame: RawFrame, light share: Float, offsets: TileOffsets) -> Double {
        let size = Self.tile
        let width = reference.width
        let planeWidth = planeWidth
        let planeHeight = planeHeight
        let noise = noise
        let theirNoise = SensorNoise(of: frame)
        let black = black
        let theirBlack = Float(frame.blackLevel)
        let blown = Float(reference.blownLevel)
        let theirBlown = Float(frame.blownLevel)
        let tolerance = tolerance
        // Only a frame that took clearly less light can say what a blown place of the reference held.
        let darker = share < 0.9
        // A tile fades in and out over its half-overlap so that tiles add up to one everywhere.
        let window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(size))) }
        let fourier = Fourier()
        // Tiles (of one colour) that differ from the reference by more than noise, by row of tiles.
        var differing = [Int](repeating: 0, count: offsets.down)
        reference.samples.withUnsafeBufferPointer { ours in
            frame.samples.withUnsafeBufferPointer { theirs in
                sum.withUnsafeMutableBufferPointer { sum in
                    weight.withUnsafeMutableBufferPointer { weight in
                        offsets.x.withUnsafeBufferPointer { offsetsX in
                            offsets.y.withUnsafeBufferPointer { offsetsY in
                                window.withUnsafeBufferPointer { window in
                                    differing.withUnsafeMutableBufferPointer { differing in
                                        let work = Work(
                                            ours: ours.baseAddress!, theirs: theirs.baseAddress!, sum: sum.baseAddress!, weight: weight.baseAddress!,
                                            offsetsX: offsetsX.baseAddress!, offsetsY: offsetsY.baseAddress!, window: window.baseAddress!,
                                            differing: differing.baseAddress!)
                                        // Rows of tiles two apart share no samples, so they can be worked on at once.
                                        for parity in 0..<2 {
                                            let rows = (offsets.down - parity + 1) / 2
                                            DispatchQueue.concurrentPerform(iterations: rows) { index in
                                                let row = index * 2 + parity
                                                var real = [Float](repeating: 0, count: size * size)
                                                var imaginary = [Float](repeating: 0, count: size * size)
                                                var moved = [Float](repeating: 0, count: size * size)
                                                var counted = [Float](repeating: 0, count: size * size)
                                                var differs = 0
                                                real.withUnsafeMutableBufferPointer { real in
                                                    imaginary.withUnsafeMutableBufferPointer { imaginary in
                                                        moved.withUnsafeMutableBufferPointer { moved in
                                                            counted.withUnsafeMutableBufferPointer { counted in
                                                                let real = real.baseAddress!
                                                                let imaginary = imaginary.baseAddress!
                                                                let moved = moved.baseAddress!
                                                                let counted = counted.baseAddress!
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
                                                                                let taken = Float(work.theirs[theirRow + 2 * min(max(x0 + dx + x, 0), planeWidth - 1)])
                                                                                // At the reference's brightness.
                                                                                let other = black + (taken - theirBlack) / share
                                                                                let at = y * size + x
                                                                                total += first
                                                                                imaginary[at] = 0
                                                                                if taken >= theirBlown {
                                                                                    // Blown in this frame: it says nothing about the place.
                                                                                    moved[at] = first
                                                                                    real[at] = 0
                                                                                    counted[at] = 0
                                                                                } else if first >= blown, darker, other >= blown - 3 * (theirNoise.variance(at: taken - theirBlack)).squareRoot() / share {
                                                                                    // Blown in the reference, and this darker frame agrees the
                                                                                    // place is that bright: its word for how bright. (Where it
                                                                                    // says otherwise something moved, and it is compared like
                                                                                    // any other place, which keeps the reference.)
                                                                                    moved[at] = other
                                                                                    real[at] = 0
                                                                                    counted[at] = share
                                                                                } else {
                                                                                    moved[at] = other
                                                                                    real[at] = first - other
                                                                                    counted[at] = share
                                                                                }
                                                                            }
                                                                        }
                                                                        // What the two frames' noise alone would make of a difference at this brightness.
                                                                        let level = max(0, total / Float(size * size) - black)
                                                                        let variance = noise.variance(at: level) + theirNoise.variance(at: level * share) / (share * share)
                                                                        let expected = Float(size * size) * variance
                                                                        let allowed = tolerance * expected
                                                                        fourier.forward(real, imaginary)
                                                                        var power: Float = 0
                                                                        var beyond: Float = 0
                                                                        for bin in 0..<(size * size) {
                                                                            let energy = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                                                                            // Near 0 where the difference is noise (the other frame is taken),
                                                                            // near 1 where it is more (the first frame is kept).
                                                                            let keep = energy / (energy + allowed)
                                                                            real[bin] *= keep
                                                                            imaginary[bin] *= keep
                                                                            // For the report, by one measure whatever the tolerance.
                                                                            power += energy
                                                                            beyond += energy * energy / (energy + 8 * expected)
                                                                        }
                                                                        if beyond > 0.5 * power { differs += 1 }
                                                                        fourier.inverse(real, imaginary)
                                                                        for y in 0..<size where y0 + y >= 0 && y0 + y < planeHeight {
                                                                            let outRow = (2 * (y0 + y) + cy) * width + cx
                                                                            for x in 0..<size where x0 + x >= 0 && x0 + x < planeWidth {
                                                                                let at = y * size + x
                                                                                let counts = work.window[x] * work.window[y] * counted[at]
                                                                                work.sum[outRow + 2 * (x0 + x)] += counts * (moved[at] + real[at])
                                                                                work.weight[outRow + 2 * (x0 + x)] += counts
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                work.differing[row] = differs
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
        return Double(differing.reduce(0, +)) / Double(max(1, offsets.across * offsets.down * 4))
    }

    /// The pointers a merge works through, shared by the rows of tiles worked on at once (which
    /// write to different samples).
    private struct Work: @unchecked Sendable {
        let ours: UnsafePointer<UInt16>
        let theirs: UnsafePointer<UInt16>
        let sum: UnsafeMutablePointer<Float>
        let weight: UnsafeMutablePointer<Float>
        let offsetsX: UnsafePointer<Int16>
        let offsetsY: UnsafePointer<Int16>
        let window: UnsafePointer<Float>
        let differing: UnsafeMutablePointer<Int>
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
