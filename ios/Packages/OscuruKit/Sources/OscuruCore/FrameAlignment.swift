import Dispatch
import Foundation

/// What lining a frame up with another and merging it found.
public struct FrameReport: Codable, Equatable, Sendable {
    /// How far the camera moved between the two, in photosites.
    public var shift: Double
    /// The share of the picture where the frame differs from the other by more than noise: what
    /// moved, or what is blurred in one of them. 0 to 1.
    public var differs: Double

    public init(shift: Double = 0, differs: Double = 0) {
        self.shift = shift
        self.differs = differs
    }
}

/// A merged raw picture, and how much brighter it is to be shown than its file says: a merge that
/// holds highlights above its first frame's white keeps them below the file's white (a file has
/// nothing above it), so the whole picture sits `brightening` stops lower in the file than it looked.
public struct MergedFrame: Sendable {
    public var frame: RawFrame
    public var brightening: Double
}

extension RawFrame {
    /// The sample value from which a photosite counts as blown: close under white, where a sensor
    /// stops answering in proportion to the light.
    public var blownLevel: Double { blackLevel + 0.95 * (whiteLevel - blackLevel) }
}

/// The sensor's noise at a sample value: its variance is `perSignal` times the value above black,
/// plus `floor`. From the file's own noise model, or measured from the frame when it has none.
struct SensorNoise: Sendable {
    var perSignal: Float
    var floor: Float

    init(of frame: RawFrame) {
        let range = max(1, frame.whiteLevel - frame.blackLevel)
        let profile = frame.noiseProfile
        if profile.count >= 2, profile[0] >= 0, profile[1] >= 0, profile[0] + profile[1] > 0 {
            perSignal = Float(profile[0] * range)
            floor = Float(profile[1] * range * range)
        } else {
            perSignal = 0
            floor = Self.measured(of: frame)
        }
    }

    func variance(at level: Float) -> Float { max(perSignal * max(0, level) + floor, 1e-3) }

    /// A frame's noise measured from the frame itself, for a file that does not say: the variance
    /// of what is left of one colour when everything smooth is taken away (Immerkær's estimate).
    static func measured(of frame: RawFrame) -> Float {
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

/// The levels of a merged picture's file. Its samples are the reference's light multiplied by a
/// power of two, as large as sixteen bits allow, so the precision the merging earned is kept. With
/// frames darker than the reference in it, white is as far above the reference's as they reach.
struct MergedLevels {
    let reference: RawFrame
    let scale: Double
    let white: Double
    let brightening: Double
    private let noiseProfile: [Double]

    /// `least` is the light of the dimmest frame merged, `light` of all of them together, both as
    /// shares of the reference's.
    init(reference: RawFrame, least: Double, light: Double, frames: Int) {
        self.reference = reference
        let headroom = 1 / min(1, max(least, 1e-3))
        let top = reference.blackLevel + (reference.whiteLevel - reference.blackLevel) * headroom
        var scale = 1.0
        while scale * 2 * top <= 65535, scale < 256 { scale *= 2 }
        while scale * top > 65535 { scale /= 2 }
        self.scale = scale
        white = (scale * top).rounded(.down)
        brightening = log2(headroom)
        // The reference's noise, less by the light gathered; on the file's scale, where white is 1.
        var profile = reference.noiseProfile
        for index in stride(from: 0, to: profile.count - 1, by: 2) {
            profile[index] *= 1 / (headroom * light)
            profile[index + 1] *= Double(frames) / (headroom * headroom * light * light)
        }
        noiseProfile = profile
    }

    func frame(_ samples: [UInt16]) -> MergedFrame {
        MergedFrame(
            frame: RawFrame(
                width: reference.width, height: reference.height, samples: samples, blackLevels: reference.blackLevels.map { $0 * scale },
                whiteLevel: white, noiseProfile: noiseProfile),
            brightening: brightening)
    }
}

/// How far each fine tile of a frame has moved against the reference, in grey pixels (each two photosites).
struct TileOffsets: Sendable {
    var across: Int
    var down: Int
    var x: [Int16]
    var y: [Int16]
    /// The same moves to a fraction of a pixel: where the difference between the tiles is least,
    /// between the whole pixels searched.
    var fx: [Float]
    var fy: [Float]

    init(across: Int, down: Int, x: [Int16], y: [Int16], fx: [Float]? = nil, fy: [Float]? = nil) {
        self.across = across
        self.down = down
        self.x = x
        self.y = y
        self.fx = fx ?? x.map(Float.init)
        self.fy = fy ?? y.map(Float.init)
    }

    /// The tiles of a frame that moves as `motion` says, each by the whole pixels nearest its centre's move.
    init(motion: Motion, across: Int, down: Int) {
        let half = BurstMerge.tile / 2
        var x = [Int16](repeating: 0, count: across * down)
        var y = [Int16](repeating: 0, count: across * down)
        var fx = [Float](repeating: 0, count: across * down)
        var fy = [Float](repeating: 0, count: across * down)
        for row in 0..<down {
            for column in 0..<across {
                let move = motion.at(Double(column * half), Double(row * half))
                let index = row * across + column
                x[index] = Int16(clamping: Int(move.x.rounded()))
                y[index] = Int16(clamping: Int(move.y.rounded()))
                fx[index] = Float(move.x)
                fy[index] = Float(move.y)
            }
        }
        self.init(across: across, down: down, x: x, y: y, fx: fx, fy: fy)
    }

    /// How far the frame as a whole moved: the middle of its tiles' moves, in photosites.
    var shift: Double {
        guard !x.isEmpty else { return 0 }
        let middleX = Double(x.sorted()[x.count / 2])
        let middleY = Double(y.sorted()[y.count / 2])
        return 2 * (middleX * middleX + middleY * middleY).squareRoot()
    }

    /// The camera's own movement between the frames, without what moved in the scene: the move at
    /// a place in the grey picture as `x = a + b·px + c·py` (and the same for y), fitted to the
    /// tiles so that those that disagree with most (something moving, or nothing to hold on to)
    /// count for little.
    /// With `within` (a rectangle of the grey picture), only the tiles in it are followed: the
    /// movement of one part of the scene, such as a subject the camera was following.
    func camera(within: (x: Double, y: Double, width: Double, height: Double)? = nil) -> CameraMove {
        let half = BurstMerge.tile / 2
        var move = CameraMove()
        guard !x.isEmpty else { return move }
        // Which tiles count: all of them, or those whose centres lie in `within` when there are enough.
        var counted = [Bool](repeating: true, count: x.count)
        if let within {
            var inside = 0
            for row in 0..<down {
                for column in 0..<across {
                    let px = Double(column * half)
                    let py = Double(row * half)
                    let yes = px >= within.x && px <= within.x + within.width && py >= within.y && py <= within.y + within.height
                    counted[row * across + column] = yes
                    if yes { inside += 1 }
                }
            }
            if inside < 6 { counted = [Bool](repeating: true, count: x.count) }
        }
        let startX = zip(fx, counted).filter(\.1).map { Double($0.0) }.sorted()
        let startY = zip(fy, counted).filter(\.1).map { Double($0.0) }.sorted()
        move.x.0 = startX.isEmpty ? 0 : startX[startX.count / 2]
        move.y.0 = startY.isEmpty ? 0 : startY[startY.count / 2]
        let centreX = Double(across - 1) * Double(half) / 2
        let centreY = Double(down - 1) * Double(half) / 2
        let reach = max(1, max(centreX, centreY))
        for _ in 0..<6 {
            // Weighted least squares, on positions measured from the middle so the sums stay small.
            var sums = [Double](repeating: 0, count: 6)
            var rightX = [Double](repeating: 0, count: 3)
            var rightY = [Double](repeating: 0, count: 3)
            for row in 0..<down {
                for column in 0..<across where counted[row * across + column] {
                    let px = Double(column * half)
                    let py = Double(row * half)
                    let u = (px - centreX) / reach
                    let v = (py - centreY) / reach
                    let foundX = Double(fx[row * across + column])
                    let foundY = Double(fy[row * across + column])
                    let offX = foundX - move.at(px, py).x
                    let offY = foundY - move.at(px, py).y
                    let distance = (offX * offX + offY * offY) / 9
                    guard distance < 1 else { continue }
                    let w = (1 - distance) * (1 - distance)
                    sums[0] += w
                    sums[1] += w * u
                    sums[2] += w * v
                    sums[3] += w * u * u
                    sums[4] += w * u * v
                    sums[5] += w * v * v
                    rightX[0] += w * foundX
                    rightX[1] += w * foundX * u
                    rightX[2] += w * foundX * v
                    rightY[0] += w * foundY
                    rightY[1] += w * foundY * u
                    rightY[2] += w * foundY * v
                }
            }
            guard let solvedX = Self.solve(sums, rightX), let solvedY = Self.solve(sums, rightY) else { break }
            // Back to positions measured from the corner.
            move.x = (solvedX[0] - solvedX[1] * centreX / reach - solvedX[2] * centreY / reach, solvedX[1] / reach, solvedX[2] / reach)
            move.y = (solvedY[0] - solvedY[1] * centreX / reach - solvedY[2] * centreY / reach, solvedY[1] / reach, solvedY[2] / reach)
        }
        return move
    }

    /// The three unknowns of a symmetric system given as its sums (1, u, v, uu, uv, vv); nil when it has no one answer.
    private static func solve(_ m: [Double], _ r: [Double]) -> [Double]? {
        let a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5]
        let determinant = a * (d * f - e * e) - b * (b * f - e * c) + c * (b * e - d * c)
        guard abs(determinant) > 1e-9 else { return nil }
        let x = (r[0] * (d * f - e * e) - b * (r[1] * f - e * r[2]) + c * (r[1] * e - d * r[2])) / determinant
        let y = (a * (r[1] * f - e * r[2]) - r[0] * (b * f - e * c) + c * (b * r[2] - r[1] * c)) / determinant
        let z = (a * (d * r[2] - r[1] * e) - b * (b * r[2] - r[1] * c) + r[0] * (b * e - d * c)) / determinant
        return [x, y, z]
    }
}

/// Where a frame's picture lies against the base's, at each place of the base's grey picture, in
/// grey pixels (two photosites each): the frame's picture of the place at (px, py) of the base is
/// at (px, py) + `at(px, py)` in the frame.
enum Motion: Sendable {
    /// None: a camera that did not move.
    case none
    /// The camera's own movement, the same for the whole scene however things in it moved.
    case camera(CameraMove)
    /// Each part of the picture on its own: things that moved are followed too.
    case tiles(TileOffsets)

    func at(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
        switch self {
        case .none: return (0, 0)
        case .camera(let move): return move.at(px, py)
        case .tiles(let tiles):
            // Between the four nearest tile centres, which are half a tile apart.
            let half = Double(BurstMerge.tile / 2)
            let u = min(max(px / half, 0), Double(tiles.across - 1))
            let v = min(max(py / half, 0), Double(tiles.down - 1))
            let c0 = min(Int(u), tiles.across - 1)
            let r0 = min(Int(v), tiles.down - 1)
            let c1 = min(c0 + 1, tiles.across - 1)
            let r1 = min(r0 + 1, tiles.down - 1)
            let a = u - Double(c0)
            let b = v - Double(r0)
            func blend(_ values: [Float]) -> Double {
                let top = Double(values[r0 * tiles.across + c0]) * (1 - a) + Double(values[r0 * tiles.across + c1]) * a
                let bottom = Double(values[r1 * tiles.across + c0]) * (1 - a) + Double(values[r1 * tiles.across + c1]) * a
                return top * (1 - b) + bottom * b
            }
            return (blend(tiles.fx), blend(tiles.fy))
        }
    }
}

/// A frame's move against another as the camera's own movement: see `TileOffsets.camera`.
struct CameraMove: Sendable {
    var x: (Double, Double, Double) = (0, 0, 0)
    var y: (Double, Double, Double) = (0, 0, 0)

    func at(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
        (x.0 + x.1 * px + x.2 * py, y.0 + y.1 * px + y.2 * py)
    }
}

/// Lining one frame up with another, tile by tile, from a coarse copy of each down to the grey at half size.
enum Alignment {
    /// Where each fine tile of `frame` lies against `reference`. `light` is the light `frame`
    /// took as a share of the reference's; `pyramid` is the reference's own, used as it is when
    /// the two were exposed alike.
    static func offsets(of frame: RawFrame, light: Double, against reference: RawFrame, pyramid plain: [Grey], tilesAcross: Int, tilesDown: Int) -> TileOffsets {
        let pyramid: [Grey]
        let other: [Grey]
        if abs(log2(light)) < 0.1 {
            pyramid = plain
            other = Grey.pyramid(of: frame)
        } else {
            // Both brought to the scale of the one that took more light, and cut off where either is blown.
            let ours = Float(max(1, light))
            let theirs = Float(max(1, 1 / light))
            let ceiling = min(Float(reference.blownLevel - reference.blackLevel) * ours, Float(frame.blownLevel - frame.blackLevel) * theirs, 65535)
            pyramid = Grey.pyramid(of: reference, gain: ours, ceiling: ceiling)
            other = Grey.pyramid(of: frame, gain: theirs, ceiling: ceiling)
        }
        // From the coarsest copy to the finest, each starting from what the coarser one found.
        var coarse: TileOffsets?
        var coarseTile = 0
        for level in stride(from: pyramid.count - 1, through: 0, by: -1) {
            let ours = pyramid[level]
            let theirs = other[level]
            let finest = level == 0
            let size = min(BurstMerge.tile, max(4, min(ours.width, ours.height)))
            let step = finest ? BurstMerge.tile / 2 : size
            let start = finest ? -BurstMerge.tile / 2 : 0
            let across = finest ? tilesAcross : (ours.width + size - 1) / size
            let down = finest ? tilesDown : (ours.height + size - 1) / size
            // A coarser copy has already found the tile to within a pixel of its own, which is
            // `scale` here: only that much is searched again. The coarsest searches furthest.
            let scale = level + 1 < pyramid.count ? Grey.factors[level + 1] : 1
            let radius = coarse == nil ? 4 : (finest ? 1 : scale)
            var foundX = [Int16](repeating: 0, count: across * down)
            var foundY = [Int16](repeating: 0, count: across * down)
            var fineX = [Float](repeating: 0, count: across * down)
            var fineY = [Float](repeating: 0, count: across * down)
            let before = coarse
            let beforeTile = coarseTile
            ours.pixels.withUnsafeBufferPointer { reference in
                theirs.pixels.withUnsafeBufferPointer { moved in
                    foundX.withUnsafeMutableBufferPointer { foundX in
                        foundY.withUnsafeMutableBufferPointer { foundY in
                          fineX.withUnsafeMutableBufferPointer { fineX in
                            fineY.withUnsafeMutableBufferPointer { fineY in
                            let out = Found(x: foundX.baseAddress!, y: foundY.baseAddress!, fx: fineX.baseAddress!, fy: fineY.baseAddress!)
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
                                    // To a fraction of a pixel: the lowest point of the parabola through the
                                    // differences at the best move and its neighbours, each way.
                                    var fraction = (x: 0.0, y: 0.0)
                                    if finest {
                                        func vertex(_ before: Int, _ here: Int, _ after: Int) -> Double {
                                            let curve = Double(before) - 2 * Double(here) + Double(after)
                                            guard curve > 0 else { return 0 }
                                            return min(0.5, max(-0.5, (Double(before) - Double(after)) / (2 * curve)))
                                        }
                                        let here = search.difference(x0: x0, y0: y0, dx: best.x, dy: best.y, limit: Int.max)
                                        fraction.x = vertex(
                                            search.difference(x0: x0, y0: y0, dx: best.x - 1, dy: best.y, limit: Int.max), here,
                                            search.difference(x0: x0, y0: y0, dx: best.x + 1, dy: best.y, limit: Int.max))
                                        fraction.y = vertex(
                                            search.difference(x0: x0, y0: y0, dx: best.x, dy: best.y - 1, limit: Int.max), here,
                                            search.difference(x0: x0, y0: y0, dx: best.x, dy: best.y + 1, limit: Int.max))
                                    }
                                    out.fx[row * across + column] = Float(Double(best.x) + fraction.x)
                                    out.fy[row * across + column] = Float(Double(best.y) + fraction.y)
                                }
                            }
                            }
                          }
                        }
                    }
                }
            }
            coarse = TileOffsets(across: across, down: down, x: foundX, y: foundY, fx: fineX, fy: fineY)
            coarseTile = size
        }
        return coarse ?? TileOffsets(across: tilesAcross, down: tilesDown, x: [Int16](repeating: 0, count: tilesAcross * tilesDown), y: [Int16](repeating: 0, count: tilesAcross * tilesDown))
    }

    /// Where a level's answers are written, by rows of tiles worked on at once (each its own row).
    struct Found: @unchecked Sendable {
        let x: UnsafeMutablePointer<Int16>
        let y: UnsafeMutablePointer<Int16>
        let fx: UnsafeMutablePointer<Float>
        let fy: UnsafeMutablePointer<Float>
    }

    /// Comparing one tile of the reference with the same tile of another frame, moved.
    struct Search: @unchecked Sendable {
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
}

/// A frame as greys at half its size, one for every group of four photosites, and smaller copies
/// of that: what frames are lined up by.
struct Grey {
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

    /// A frame's greys. With a `gain`, each is the light above black times it, and none is more than
    /// `ceiling`: how frames of different exposures are made alike to be compared (what is blown in
    /// either is the same flat white in both).
    init(of frame: RawFrame, gain: Float = 1, ceiling: Float = 65535) {
        width = frame.width / 2
        height = frame.height / 2
        pixels = [UInt16](repeating: 0, count: width * height)
        let width = width
        let height = height
        let plain = gain == 1 && ceiling >= 65535
        let black = Float(frame.blackLevel)
        frame.samples.withUnsafeBufferPointer { samples in
            pixels.withUnsafeMutableBufferPointer { pixels in
                for y in 0..<height {
                    let top = 2 * y * frame.width
                    let bottom = top + frame.width
                    for x in 0..<width {
                        let total = Int(samples[top + 2 * x]) + Int(samples[top + 2 * x + 1]) + Int(samples[bottom + 2 * x]) + Int(samples[bottom + 2 * x + 1])
                        if plain {
                            pixels[y * width + x] = UInt16(total / 4)
                        } else {
                            pixels[y * width + x] = UInt16(min(ceiling, max(0, (Float(total) / 4 - black) * gain)))
                        }
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
    static func pyramid(of frame: RawFrame, gain: Float = 1, ceiling: Float = 65535) -> [Grey] {
        var levels = [Grey(of: frame, gain: gain, ceiling: ceiling)]
        for factor in factors.dropFirst() {
            guard let last = levels.last, last.width / factor >= 16, last.height / factor >= 16 else { break }
            levels.append(last.reduced(by: factor))
        }
        return levels
    }
}


extension Alignment {
    /// The tiles' moves to a small fraction of a photosite, for merging onto a finer grid, where a
    /// sample put a third of a photosite from where it fell blurs what it was meant to sharpen. The
    /// grey at half size that frames are searched on is too coarse for that, so each tile is
    /// followed on the light of every group of four photosites (taken at every photosite, so
    /// nothing is lost to halving), by the gradients of the reference (after Lucas and Kanade): a
    /// few steps, each the move that best explains what still differs.
    /// Fine repeating things (roof tiles, gravel, cloth) look alike a stripe further on, and a tile
    /// alone can settle there; so each tile is followed from where `camera` (the frame's movement
    /// as a whole) puts it, and from its own search, and keeps its own only where that explains it
    /// clearly better (something that moved on its own). A tile with too little to hold on to, or
    /// that wanders off, keeps the move it had.
    static func refined(_ offsets: TileOffsets, of frame: RawFrame, light: Double, against reference: RawFrame, camera: CameraMove? = nil) -> TileOffsets {
        var out = offsets
        let width = reference.width
        let height = reference.height
        // As in `offsets`: both at the scale of the one that took more light, cut off where either is blown.
        let ourGain = Float(max(1, light))
        let theirGain = Float(max(1, 1 / light))
        let ceiling = Float.minimum(Float(reference.blownLevel - reference.blackLevel) * ourGain, Float(frame.blownLevel - frame.blackLevel) * theirGain)
        let ourBlack = Float((0..<4).map { reference.black($0 % 2, $0 / 2) }.reduce(0, +))
        let theirBlack = Float((0..<4).map { frame.black($0 % 2, $0 / 2) }.reduce(0, +))
        let tile = BurstMerge.tile * 2
        let across = offsets.across
        // The light of the four photosites from each photosite, in either frame.
        func groups(of frame: RawFrame, black: Float, gain: Float) -> [Float] {
            var out = [Float](repeating: 0, count: width * height)
            frame.samples.withUnsafeBufferPointer { samples in
                out.withUnsafeMutableBufferPointer { out in
                    let samples = UnsafeSendable(samples.baseAddress!)
                    let target = UnsafeMutableSendable(out.baseAddress!)
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        let cy = min(y, height - 2)
                        for x in 0..<width {
                            let at = cy * width + min(x, width - 2)
                            let sum = Float(samples.pointer[at]) + Float(samples.pointer[at + 1]) + Float(samples.pointer[at + width]) + Float(samples.pointer[at + width + 1])
                            target.pointer[y * width + x] = min(ceiling * 4, max(0, sum - black) * gain)
                        }
                    }
                }
            }
            return out
        }
        let ourGroups = groups(of: reference, black: ourBlack, gain: ourGain)
        let theirGroups = groups(of: frame, black: theirBlack, gain: theirGain)
        out.fx.withUnsafeMutableBufferPointer { fx in
            out.fy.withUnsafeMutableBufferPointer { fy in
                ourGroups.withUnsafeBufferPointer { ours in
                    theirGroups.withUnsafeBufferPointer { theirs in
                        let fx = UnsafeMutableSendable(fx.baseAddress!)
                        let fy = UnsafeMutableSendable(fy.baseAddress!)
                        let ours = UnsafeSendable(ours.baseAddress!)
                        let theirs = UnsafeSendable(theirs.baseAddress!)
                        DispatchQueue.concurrentPerform(iterations: offsets.down) { row in
                            func group(_ groups: UnsafePointer<Float>, _ x: Int, _ y: Int) -> Float {
                                groups[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
                            }
                            func theirsAt(_ x: Float, _ y: Float) -> Float {
                                let x0 = Int(x.rounded(.down))
                                let y0 = Int(y.rounded(.down))
                                let a = x - Float(x0)
                                let b = y - Float(y0)
                                let g = theirs.pointer
                                guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else {
                                    let top = group(g, x0, y0) * (1 - a) + group(g, x0 + 1, y0) * a
                                    let bottom = group(g, x0, y0 + 1) * (1 - a) + group(g, x0 + 1, y0 + 1) * a
                                    return top * (1 - b) + bottom * b
                                }
                                let at = y0 * width + x0
                                let top = g[at] * (1 - a) + g[at + 1] * a
                                let bottom = g[at + width] * (1 - a) + g[at + width + 1] * a
                                return top * (1 - b) + bottom * b
                            }
                            var reference = [Float](repeating: 0, count: tile * tile)
                            var gradientX = [Float](repeating: 0, count: tile * tile)
                            var gradientY = [Float](repeating: 0, count: tile * tile)
                            for column in 0..<across {
                                let index = row * across + column
                                // The tile in photosites: where the grey tile lies, at twice the scale.
                                let left = 2 * (-BurstMerge.tile / 2 + column * BurstMerge.tile / 2)
                                let top = 2 * (-BurstMerge.tile / 2 + row * BurstMerge.tile / 2)
                                guard left >= 1, top >= 1, left + tile + 2 < width, top + tile + 2 < height else {
                                    // At the edge, where a tile hangs over, the frame's movement as a whole.
                                    if let camera {
                                        let move = camera.at(Double(left / 2 + BurstMerge.tile / 2), Double(top / 2 + BurstMerge.tile / 2))
                                        fx.pointer[index] = Float(move.x)
                                        fy.pointer[index] = Float(move.y)
                                    }
                                    continue
                                }
                                var xx: Float = 0
                                var xy: Float = 0
                                var yy: Float = 0
                                for j in 0..<tile {
                                    for i in 0..<tile {
                                        let x = left + i
                                        let y = top + j
                                        reference[j * tile + i] = group(ours.pointer, x, y)
                                        let gx = (group(ours.pointer, x + 1, y) - group(ours.pointer, x - 1, y)) / 2
                                        let gy = (group(ours.pointer, x, y + 1) - group(ours.pointer, x, y - 1)) / 2
                                        gradientX[j * tile + i] = gx
                                        gradientY[j * tile + i] = gy
                                        xx += gx * gx
                                        xy += gx * gy
                                        yy += gy * gy
                                    }
                                }
                                // How much the tiles still differ with the frame moved by `move`, in photosites.
                                func residual(_ move: (x: Float, y: Float)) -> Float {
                                    var total: Float = 0
                                    for j in 0..<tile {
                                        for i in 0..<tile {
                                            let difference = theirsAt(Float(left + i) + move.x, Float(top + j) + move.y) - reference[j * tile + i]
                                            total += difference * difference
                                        }
                                    }
                                    return total
                                }
                                let determinant = xx * yy - xy * xy
                                let trace = xx + yy
                                let holds = trace > 1e-3 && determinant > 0.05 * trace * trace / 4
                                // Followed from `start`; nil when it wanders off.
                                func followed(from start: (x: Float, y: Float)) -> (x: Float, y: Float)? {
                                    guard holds else { return start }
                                    var move = start
                                    for _ in 0..<6 {
                                        var bx: Float = 0
                                        var by: Float = 0
                                        for j in 0..<tile {
                                            for i in 0..<tile {
                                                let difference = theirsAt(Float(left + i) + move.x, Float(top + j) + move.y) - reference[j * tile + i]
                                                bx += gradientX[j * tile + i] * difference
                                                by += gradientY[j * tile + i] * difference
                                            }
                                        }
                                        let stepX = -(yy * bx - xy * by) / determinant
                                        let stepY = -(xx * by - xy * bx) / determinant
                                        move.x += stepX
                                        move.y += stepY
                                        if stepX * stepX + stepY * stepY < 1e-4 { break }
                                    }
                                    guard move.x.isFinite, move.y.isFinite, abs(move.x - start.x) <= 1.5, abs(move.y - start.y) <= 1.5 else { return nil }
                                    return move
                                }
                                let own = (x: 2 * fx.pointer[index], y: 2 * fy.pointer[index])
                                var best = followed(from: own)
                                if let camera {
                                    let predicted = camera.at(Double(left / 2 + BurstMerge.tile / 2), Double(top / 2 + BurstMerge.tile / 2))
                                    if let along = followed(from: (Float(2 * predicted.x), Float(2 * predicted.y))) {
                                        // Its own only where that explains it far better.
                                        if let mine = best, residual(mine) < 0.5 * residual(along) {
                                            best = mine
                                        } else {
                                            best = along
                                        }
                                    }
                                }
                                guard let best else { continue }
                                fx.pointer[index] = best.x / 2
                                fy.pointer[index] = best.y / 2
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
