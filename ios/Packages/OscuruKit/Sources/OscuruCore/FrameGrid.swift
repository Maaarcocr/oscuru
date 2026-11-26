import Dispatch
import Foundation

/// Merging frames onto a finer grid than the sensor's (super-resolution, after Wronski and others,
/// "Handheld multi-frame super-resolution", 2019). A hand never holds still: between frames the
/// camera moves by fractions of a photosite, so the frames' samples of the scene fall at different
/// places, and together they sample it more finely than any one of them. Each pixel of the finer
/// grid is made from the samples of every frame that fell near it, each where it fell (from
/// alignment to a fraction of a pixel), each colour from its own photosites: so every pixel gets
/// all three colours, measured, with nothing filled in between.
///
/// Each frame's samples near a pixel are weighed by how near they fell. Combined `robust`ly (or by
/// the mean), all the samples of all the frames are averaged together, a frame counting for less
/// where it differs from the base beyond noise (something moved there); every other way of
/// combining first gives each frame its own value at the pixel and then combines those (`Reducer`).
/// The picture is linear red, green and blue, in the camera's own colours.
enum GridMerge {
    /// How far a sample's weight reaches, in photosites, where there is detail, for this many
    /// frames: the more frames, the more closely their samples lie, and the nearer ones are enough
    /// (reaching further only blurs). Green photosites are twice as many as red or blue ones, so
    /// theirs reaches less far.
    static func reach(frames: Int) -> (green: Float, other: Float) {
        let frames = Float(max(1, frames)).squareRoot()
        return (min(0.55, max(0.2, 0.6 / frames)), min(0.85, max(0.3, 0.84 / frames)))
    }

    /// How far it reaches where the picture is flat (a sky, a wall), where there is nothing to
    /// sharpen and more samples average more noise away.
    static let flatReach: (green: Float, other: Float) = (0.7, 1.0)

    /// A sample's weight by where it fell in the 4×4 photosites around a pixel's place, for each
    /// sixteenth of a photosite that place can fall at, each way.
    static func weights(reach: Float) -> [Float] {
        var table = [Float](repeating: 0, count: 16 * 16 * 16)
        for fy in 0..<16 {
            for fx in 0..<16 {
                for j in 0..<4 {
                    for i in 0..<4 {
                        let dx = Float(i - 1) - (Float(fx) + 0.5) / 16
                        let dy = Float(j - 1) - (Float(fy) + 0.5) / 16
                        table[((fy * 16 + fx) * 4 + j) * 4 + i] = exp(-(dx * dx + dy * dy) / (2 * reach * reach))
                    }
                }
            }
        }
        return table
    }

    static func merge(_ stack: [FrameMerging.Layer], combine: FrameMerge.Combine, scale: Int, tolerance: Float) -> (picture: MergedPicture, differs: [Double]) {
        let reference = stack[0].frame
        let width = reference.width
        let height = reference.height
        let outWidth = width * scale
        let outHeight = height * scale
        let count = stack.count
        // The weights for four steps between flat and detailed.
        let reach = GridMerge.reach(frames: count)
        let flat = GridMerge.flatReach
        // Four steps, each green then red and blue, one after the other.
        let tables: [Float] = (0..<4).flatMap { step -> [Float] in
            let detail = Float(step) / 3
            return GridMerge.weights(reach: flat.green + (reach.green - flat.green) * detail) + GridMerge.weights(reach: flat.other + (reach.other - flat.other) * detail)
        }
        let joint = combine == .robust || combine == .mean
        let robust = combine == .robust
        let reducer = Reducer(combine: combine, tolerance: tolerance)
        let shares = stack.map { Float($0.light) }
        let blown = stack.map { Float($0.frame.blownLevel) }
        let noises = stack.map { SensorNoise(of: $0.frame) }
        let black = Float(reference.blackLevel)
        let motions = stack.map(\.motion)
        // Each frame's colour at each place of the pattern, and its black there (for frames that give one per place).
        let cfas: [Int] = stack.flatMap(\.frame.cfa)
        let blacks: [Float] = stack.flatMap { layer in (0..<4).map { Float(layer.frame.black($0 % 2, $0 / 2)) } }
        // What robust combining compares: each frame's grey (at half size) against the base's, and
        // how much the base itself varies around each place (where it does, a frame lined up a
        // little off differs from it without anything having moved).
        let greys = robust ? stack.map { Grey(of: $0.frame) } : [Grey(of: reference)]
        let variation = GridMerge.variation(greys[0])
        let details = combine == .sharpest ? stack.map { Detail(of: $0.frame, light: $0.light) } : nil
        let k = tolerance / 2
        let levels = MergedLevels(reference: reference, least: Double(shares.min() ?? 1), light: Double(shares.reduce(0, +)), frames: count)
        let factor = Float(levels.scale)
        let white = Float(levels.white)

        var out = [UInt16](repeating: 0, count: outWidth * outHeight * 3)
        var differing = [Int](repeating: 0, count: count * outHeight)
        PlaceMerge.withSamples(stack.map(\.frame)) { samples in
            out.withUnsafeMutableBufferPointer { out in
                differing.withUnsafeMutableBufferPointer { differing in
                  tables.withUnsafeBufferPointer { tables in
                    cfas.withUnsafeBufferPointer { cfas in
                      blacks.withUnsafeBufferPointer { blacks in
                    let tables = UnsafeSendable(tables.baseAddress!)
                    let cfas = UnsafeSendable(cfas.baseAddress!)
                    let blacks = UnsafeSendable(blacks.baseAddress!)
                    let target = UnsafeMutableSendable(out.baseAddress!)
                    let counts = UnsafeMutableSendable(differing.baseAddress!)
                    let sources = samples.map { UnsafeSendable($0) }
                    DispatchQueue.concurrentPerform(iterations: outHeight) { oy in
                        var values = [Float](repeating: 0, count: count * 3)
                        var variances = [Float](repeating: 0, count: count * 3)
                        var valid = [Bool](repeating: false, count: count * 3)
                        var channel = [Float](repeating: 0, count: count)
                        var channelVariance = [Float](repeating: 0, count: count)
                        var channelValid = [Bool](repeating: false, count: count)
                        var sorted = [Float](repeating: 0, count: count)
                        var detail = [Float](repeating: 0, count: count)
                        var differs = [Int](repeating: 0, count: count)
                        let y = (Float(oy) + 0.5) / Float(scale) - 0.5
                        for ox in 0..<outWidth {
                            let x = (Float(ox) + 0.5) / Float(scale) - 0.5
                            // Where the pixel is on the base's grey picture.
                            let gx = Double((x - 0.5) / 2)
                            let gy = Double((y - 0.5) / 2)
                            // How detailed the base is here, beyond its noise: how far samples reach.
                            let baseNoise = noises[0].variance(at: max(0, greys[0].sample(gx, gy) - black)) / 4
                            let excess = max(0, variation.sample(gx, gy, width: greys[0].width, height: greys[0].height) - baseNoise)
                            let table = tables.pointer + min(3, Int((excess / (excess + 2 * baseNoise + 1e-6) * 3).rounded())) * 2 * 4096
                            var number: (Float, Float, Float) = (0, 0, 0)
                            var weight: (Float, Float, Float) = (0, 0, 0)
                            for index in 0..<count {
                                let move = motions[index].at(gx, gy)
                                let fx = x + Float(2 * move.x)
                                let fy = y + Float(2 * move.y)
                                let left = Int(fx.rounded(.down))
                                let top = Int(fy.rounded(.down))
                                let cell = (min(15, max(0, Int((fy - Float(top)) * 16))) * 16 + min(15, max(0, Int((fx - Float(left)) * 16)))) * 16
                                let source = sources[index].pointer
                                let cfa = cfas.pointer + index * 4
                                let black4 = blacks.pointer + index * 4
                                var sums: (Float, Float, Float) = (0, 0, 0)
                                var totals: (Float, Float, Float) = (0, 0, 0)
                                var squares: (Float, Float, Float) = (0, 0, 0)
                                for j in 0..<4 {
                                    let sy = min(max(top - 1 + j, 0), height - 1)
                                    for i in 0..<4 {
                                        let sx = min(max(left - 1 + i, 0), width - 1)
                                        let taken = Float(source[sy * width + sx])
                                        guard taken < blown[index] else { continue }
                                        let place = (sy & 1) * 2 + (sx & 1)
                                        let colour = cfa[place]
                                        let w = table[(colour == 1 ? 0 : 4096) + cell + j * 4 + i]
                                        // At the base's brightness.
                                        let value = black + (taken - black4[place]) / shares[index]
                                        switch colour {
                                        case 0: sums.0 += w * value; totals.0 += w; squares.0 += w * w
                                        case 1: sums.1 += w * value; totals.1 += w; squares.1 += w * w
                                        default: sums.2 += w * value; totals.2 += w; squares.2 += w * w
                                        }
                                    }
                                }
                                if joint {
                                    // A frame counts for the light it took, and (robustly) for less where it differs from the base.
                                    var trust = shares[index]
                                    if robust, index > 0 {
                                        let mine = greys[index].sample(Double((fx - 0.5) / 2), Double((fy - 0.5) / 2))
                                        let theirs = black + (mine - black4[0]) / shares[index]
                                        let ours = greys[0].sample(gx, gy)
                                        let level = max(0, ours - black)
                                        let noise = (noises[0].variance(at: level) + noises[index].variance(at: level * shares[index]) / (shares[index] * shares[index])) / 4
                                        let allowed = k * max(noise, 0.5 * variation.sample(gx, gy, width: greys[0].width, height: greys[0].height))
                                        let difference = theirs - ours
                                        let robustness = exp(-max(0, difference * difference / max(allowed, 1e-3) - 1))
                                        if robustness < 0.5 { differs[index] += 1 }
                                        trust *= robustness
                                    }
                                    number.0 += trust * sums.0; weight.0 += trust * totals.0
                                    number.1 += trust * sums.1; weight.1 += trust * totals.1
                                    number.2 += trust * sums.2; weight.2 += trust * totals.2
                                } else {
                                    // The frame's own value of each colour at the pixel, and its noise.
                                    let sumsArray = [sums.0, sums.1, sums.2]
                                    let totalsArray = [totals.0, totals.1, totals.2]
                                    let squaresArray = [squares.0, squares.1, squares.2]
                                    for c in 0..<3 {
                                        let slot = c * count + index
                                        valid[slot] = totalsArray[c] > 1e-4
                                        guard valid[slot] else { continue }
                                        let value = sumsArray[c] / totalsArray[c]
                                        values[slot] = value
                                        let spread = squaresArray[c] / (totalsArray[c] * totalsArray[c])
                                        variances[slot] = noises[index].variance(at: max(0, value - black) * shares[index]) / (shares[index] * shares[index]) * spread
                                    }
                                    if let details {
                                        detail[index] = details[index].at(Int(((fx - 0.5) / 2).rounded()), Int(((fy - 0.5) / 2).rounded()))
                                    }
                                }
                            }
                            var rgb: (Float, Float, Float)
                            if joint {
                                // Blown in every frame: as bright as anything can be.
                                rgb = (
                                    weight.0 > 1e-6 ? number.0 / weight.0 : .infinity, weight.1 > 1e-6 ? number.1 / weight.1 : .infinity,
                                    weight.2 > 1e-6 ? number.2 / weight.2 : .infinity
                                )
                            } else {
                                var result: [Float] = [0, 0, 0]
                                for c in 0..<3 {
                                    for index in 0..<count {
                                        channel[index] = values[c * count + index]
                                        channelVariance[index] = variances[c * count + index]
                                        channelValid[index] = valid[c * count + index]
                                    }
                                    let value = channel.withUnsafeBufferPointer { channel in
                                        channelVariance.withUnsafeBufferPointer { channelVariance in
                                            shares.withUnsafeBufferPointer { shares in
                                                channelValid.withUnsafeBufferPointer { channelValid in
                                                    detail.withUnsafeBufferPointer { detail in
                                                        sorted.withUnsafeMutableBufferPointer { sorted in
                                                            differs.withUnsafeMutableBufferPointer { differs in
                                                                reducer.reduce(
                                                                    count, values: channel.baseAddress!, variances: channelVariance.baseAddress!, light: shares.baseAddress!,
                                                                    valid: channelValid.baseAddress!, detail: details == nil ? nil : detail.baseAddress!,
                                                                    sorted: sorted.baseAddress!, differs: differs.baseAddress!)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    result[c] = value ?? .infinity
                                }
                                rgb = (result[0], result[1], result[2])
                            }
                            let at = (oy * outWidth + ox) * 3
                            target.pointer[at] = UInt16(max(0, min(white, (rgb.0 * factor).rounded())))
                            target.pointer[at + 1] = UInt16(max(0, min(white, (rgb.1 * factor).rounded())))
                            target.pointer[at + 2] = UInt16(max(0, min(white, (rgb.2 * factor).rounded())))
                        }
                        for index in 0..<count { counts.pointer[oy * count + index] = differs[index] }
                    }
                      }
                    }
                  }
                }
            }
        }
        var differs: [Double] = []
        let places = Double(outWidth * outHeight) * (joint ? 1 : 3)
        for index in 0..<count {
            var total = 0
            for row in 0..<outHeight { total += differing[row * count + index] }
            differs.append(Double(total) / places)
        }
        let frame = RGBFrame(
            width: outWidth, height: outHeight, samples: out, blackLevel: Double(black) * levels.scale, whiteLevel: levels.white,
            noiseProfile: levels.frame([]).frame.noiseProfile)
        return (.rgb(frame, brightening: levels.brightening), differs)
    }

    /// How much the grey picture varies around each place: the variance of each 3×3.
    static func variation(_ grey: Grey) -> [Float] {
        let width = grey.width
        let height = grey.height
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                var squares: Float = 0
                for dy in -1...1 {
                    let row = min(max(y + dy, 0), height - 1) * width
                    for dx in -1...1 {
                        let value = Float(grey.pixels[row + min(max(x + dx, 0), width - 1)])
                        sum += value
                        squares += value * value
                    }
                }
                let mean = sum / 9
                out[y * width + x] = max(0, squares / 9 - mean * mean)
            }
        }
        return out
    }
}

extension Grey {
    /// The grey between pixels, at (x, y) in pixels of this picture.
    func sample(_ x: Double, _ y: Double) -> Float {
        let cx = min(max(x, 0), Double(width - 1))
        let cy = min(max(y, 0), Double(height - 1))
        let x0 = Int(cx)
        let y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let a = Float(cx - Double(x0))
        let b = Float(cy - Double(y0))
        let top = Float(pixels[y0 * width + x0]) * (1 - a) + Float(pixels[y0 * width + x1]) * a
        let bottom = Float(pixels[y1 * width + x0]) * (1 - a) + Float(pixels[y1 * width + x1]) * a
        return top * (1 - b) + bottom * b
    }
}

extension Array where Element == Float {
    /// A value of a picture laid out row after row, at (x, y) between its pixels.
    func sample(_ x: Double, _ y: Double, width: Int, height: Int) -> Float {
        let cx = Int(Swift.min(Swift.max(x.rounded(), 0), Double(width - 1)))
        let cy = Int(Swift.min(Swift.max(y.rounded(), 0), Double(height - 1)))
        return self[cy * width + cx]
    }
}
