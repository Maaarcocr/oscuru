import Foundation

/// Histogram and statistics of a rendered photo, measured on a small sRGB RGBA8 bitmap of it.
/// All values are display-referred, 0 to 1 unless noted.
public struct ImageAnalysis: Equatable, Sendable {
    public struct Histogram: Equatable, Sendable {
        /// Fraction of pixels per bin, from black (index 0) to white (index 255). Each sums to 1.
        public var luminance: [Double]
        public var red: [Double]
        public var green: [Double]
        public var blue: [Double]
        /// Fraction of pixels with at least one channel at the very top.
        public var highlightClipping: Double
        /// Fraction of pixels with every channel at the very bottom.
        public var shadowClipping: Double

        public var json: JSONValue {
            func bins(_ values: [Double]) -> JSONValue { .array(values.map { .number($0) }) }
            return [
                "bins": 256, "luminance": bins(luminance), "red": bins(red), "green": bins(green), "blue": bins(blue),
                "highlightClipping": .number(highlightClipping), "shadowClipping": .number(shadowClipping),
            ]
        }
    }

    public var histogram: Histogram
    /// The statistics as the JSON object scripts and the model receive (see `ImageStatistics` in the API).
    public var statistics: JSONValue

    public var meanLuminance: Double { statistics["meanLuminance"]?.doubleValue ?? 0 }

    public func colorShare(_ range: String) -> Double { statistics["colorDistribution"]?[range]?.doubleValue ?? 0 }

    static let clipHigh = 253
    static let clipLow = 2

    /// Measures an sRGB RGBA8 bitmap (row-major, top row first). Nil when the bitmap is empty or too short.
    public init?(pixels: Data, width: Int, height: Int) {
        let count = width * height
        guard width > 0, height > 0, pixels.count >= count * 4 else { return nil }
        var luminance = [Int](repeating: 0, count: 256)
        var red = [Int](repeating: 0, count: 256)
        var green = [Int](repeating: 0, count: 256)
        var blue = [Int](repeating: 0, count: 256)
        var zoneSum = [Double](repeating: 0, count: 9)
        var zoneCount = [Int](repeating: 0, count: 9)
        var rangeCount = [Int](repeating: 0, count: 8)
        var neutral = 0
        var highlightClipped = 0
        var shadowClipped = 0
        var clippedRed = 0
        var clippedGreen = 0
        var clippedBlue = 0
        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var sumY = 0.0
        var sumY2 = 0.0
        var sumSaturation = 0.0

        pixels.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for y in 0..<height {
                let zoneRow = min(2, y * 3 / height)
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let r = Int(buffer[offset])
                    let g = Int(buffer[offset + 1])
                    let b = Int(buffer[offset + 2])
                    let value = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                    luminance[min(255, Int(value.rounded()))] += 1
                    red[r] += 1
                    green[g] += 1
                    blue[b] += 1
                    sumR += Double(r)
                    sumG += Double(g)
                    sumB += Double(b)
                    sumY += value
                    sumY2 += value * value
                    let zone = zoneRow * 3 + min(2, x * 3 / width)
                    zoneSum[zone] += value
                    zoneCount[zone] += 1
                    let maxValue = max(r, g, b)
                    let minValue = min(r, g, b)
                    if maxValue >= ImageAnalysis.clipHigh { highlightClipped += 1 }
                    if maxValue <= ImageAnalysis.clipLow { shadowClipped += 1 }
                    if r >= ImageAnalysis.clipHigh { clippedRed += 1 }
                    if g >= ImageAnalysis.clipHigh { clippedGreen += 1 }
                    if b >= ImageAnalysis.clipHigh { clippedBlue += 1 }
                    let chroma = Double(maxValue - minValue)
                    let saturation = maxValue == 0 ? 0 : chroma / Double(maxValue)
                    sumSaturation += saturation
                    if saturation < 0.15 || maxValue < 30 {
                        neutral += 1
                    } else {
                        let hue = ColorPipeline.hue(Double(r), Double(g), Double(b), max: Double(maxValue), chroma: chroma)
                        // Nearest range centre around the wheel.
                        var best = 0
                        var bestDistance = 360.0
                        for (index, centre) in ColorPipeline.rangeHues.enumerated() {
                            let distance = min(abs(hue - centre), 360 - abs(hue - centre))
                            if distance < bestDistance {
                                bestDistance = distance
                                best = index
                            }
                        }
                        rangeCount[best] += 1
                    }
                }
            }
        }

        func round(_ value: Double, _ digits: Int = 4) -> Double {
            let scale = pow(10, Double(digits))
            return (value * scale).rounded() / scale
        }
        let total = Double(count)
        func percentile(_ fraction: Double) -> Double {
            let target = fraction * total
            var seen = 0.0
            for (index, bin) in luminance.enumerated() {
                seen += Double(bin)
                if seen >= target { return round(Double(index) / 255) }
            }
            return 1
        }
        func normalized(_ bins: [Int]) -> [Double] { bins.map { round(Double($0) / total, 5) } }
        let mean = sumY / total
        let meanR = sumR / total / 255
        let meanG = sumG / total / 255
        let meanB = sumB / total / 255
        let grey = (meanR + meanG + meanB) / 3
        let p1 = percentile(0.01)
        let p99 = percentile(0.99)
        var distribution: [String: JSONValue] = ["neutral": .number(round(Double(neutral) / total))]
        for (index, name) in Specs.colorRanges.enumerated() { distribution[name] = .number(round(Double(rangeCount[index]) / total)) }
        let zones: [JSONValue] = (0..<3).map { row in
            .array((0..<3).map { column in .number(round(zoneSum[row * 3 + column] / Double(max(1, zoneCount[row * 3 + column])) / 255, 3)) })
        }
        let highlightClipping = round(Double(highlightClipped) / total)
        let shadowClipping = round(Double(shadowClipped) / total)

        histogram = Histogram(
            luminance: normalized(luminance), red: normalized(red), green: normalized(green), blue: normalized(blue),
            highlightClipping: highlightClipping, shadowClipping: shadowClipping)
        statistics = [
            "width": .number(Double(width)),
            "height": .number(Double(height)),
            "meanLuminance": .number(round(mean / 255)),
            "medianLuminance": .number(percentile(0.5)),
            "percentiles": [
                "p1": .number(p1), "p5": .number(percentile(0.05)), "p25": .number(percentile(0.25)), "p50": .number(percentile(0.5)),
                "p75": .number(percentile(0.75)), "p95": .number(percentile(0.95)), "p99": .number(p99),
            ],
            "contrast": .number(round((max(0, sumY2 / total - mean * mean)).squareRoot() / 255)),
            "dynamicRange": .number(round(p99 - p1)),
            "averageSaturation": .number(round(sumSaturation / total)),
            "meanRGB": [.number(round(meanR)), .number(round(meanG)), .number(round(meanB))],
            "colorCast": ["red": .number(round(meanR - grey)), "green": .number(round(meanG - grey)), "blue": .number(round(meanB - grey))],
            "highlightClipping": .number(highlightClipping),
            "shadowClipping": .number(shadowClipping),
            "clippedChannels": [
                "red": .number(round(Double(clippedRed) / total)), "green": .number(round(Double(clippedGreen) / total)),
                "blue": .number(round(Double(clippedBlue) / total)),
            ],
            "zones": .array(zones),
            "colorDistribution": .object(distribution),
        ]
    }
}
