import Foundation

/// A small RGBA8 picture, row-major, top row first, in encoded Display P3: what the tone and
/// colour stages work in, so curves fitted on it mean the same thing when applied.
public struct PixelBuffer: Equatable, Sendable {
    public var rgba: Data
    public var width: Int
    public var height: Int

    public init(rgba: Data, width: Int, height: Int) {
        self.rgba = rgba
        self.width = width
        self.height = height
    }

    var aspect: Double { Double(width) / Double(max(1, height)) }

    /// The colour at a point given as fractions of the picture, from its top-left corner.
    func color(atX x: Double, y: Double) -> (Double, Double, Double) {
        let column = min(width - 1, max(0, Int(x * Double(width))))
        let row = min(height - 1, max(0, Int(y * Double(height))))
        let offset = (row * width + column) * 4
        let red: UInt8 = rgba[rgba.startIndex + offset]
        let green: UInt8 = rgba[rgba.startIndex + offset + 1]
        let blue: UInt8 = rgba[rgba.startIndex + offset + 2]
        return (Double(red) / 255, Double(green) / 255, Double(blue) / 255)
    }
}

/// A look found by comparing pictures: one tone curve per channel and a saturation, ready to set
/// with the photo API.
public struct LookFit: Codable, Equatable, Sendable {
    public var curves: [String: [[Double]]]
    public var saturation: Double
    /// Average difference left after a pair fit, in 8-bit levels. Nil for a match.
    public var error: Double?

    public var json: JSONValue {
        var members: [String: JSONValue] = [
            "curves": .object(curves.mapValues { points in .array(points.map { .array($0.map { .number($0) }) }) }),
            "saturation": .number(saturation),
        ]
        if let error { members["error"] = .number(error) }
        return .object(members)
    }

    /// The settings a look replaces: the tone and colour stages. Exposure, white balance,
    /// highlights, shadows, clarity, texture and detail are the photo's own and stay.
    static let replacedGlobals = ["contrast", "whites", "blacks", "dehaze", "vibrance", "saturation"]

    /// `state` with the tone and colour stages cleared: what a look is measured on and applied to.
    /// For measuring a pair, also the whole frame with no local adjustments or effects.
    public static func base(_ state: EditingState, wholeFrame: Bool) -> EditingState {
        var result = state
        for key in replacedGlobals { result.global[key] = 0 }
        result.curves = EditingState().curves
        result.hsl = EditingState().hsl
        result.grading = EditingState().grading
        if wholeFrame {
            result.crop = Crop()
            result.local = []
            result.grain = EditingState().grain
            result.halation = EditingState().halation
            result.global["vignette"] = 0
        }
        return result
    }

    /// The look in place of `state`'s tone and colour: the three channel curves, a straight master
    /// curve, the saturation, and the rest of the tone and colour stages cleared.
    public func applied(to state: EditingState) throws -> EditingState {
        var result = LookFit.base(state, wholeFrame: false)
        for (channel, points) in curves {
            try result.setCurve(channel: .string(channel), points: .array(points.map { .array($0.map { .number($0) }) }))
        }
        try result.adjust(["saturation": .number(saturation)])
        return result
    }

    /// Reads a look a script passes back, checking it like any other settings.
    public init(json: JSONValue) throws {
        guard let members = json.objectValue else { throw StateError("a look must be an object with curves and a saturation") }
        guard let curveMembers = members["curves"]?.objectValue else { throw StateError("look.curves must be an object with red, green and blue curves") }
        var curves: [String: [[Double]]] = [:]
        for (channel, points) in curveMembers {
            guard ["red", "green", "blue"].contains(channel) else { throw StateError("look.curves has no channel \"\(channel)\"; it has red, green and blue") }
            curves[channel] = try EditingState.normalizeCurve("look.curves.\(channel)", points)
        }
        let saturation = members["saturation"]?.doubleValue ?? 0
        guard saturation.isFinite, saturation >= -100, saturation <= 100 else { throw StateError("look.saturation must be between -100 and 100") }
        self.init(curves: curves, saturation: saturation, error: members["error"]?.doubleValue)
    }

    public init(curves: [String: [[Double]]], saturation: Double, error: Double? = nil) {
        self.curves = curves
        self.saturation = saturation
        self.error = error
    }
}

/// The tone and colour of a picture, as a style learned from one picture keeps it: where each
/// channel's darkest, middle and brightest values fall, and how colourful it is.
public struct StyleFingerprint: Codable, Equatable, Sendable {
    /// For "red", "green" and "blue": the value at each of `LookFitting.matchQuantiles`.
    public var quantiles: [String: [Double]]
    public var colourfulness: Double

    public init(quantiles: [String: [Double]], colourfulness: Double) {
        self.quantiles = quantiles
        self.colourfulness = colourfulness
    }
}

/// Learning a look from pictures: exactly from a pair (an original and its edit), or approximately
/// from one reference of any scene. It is measurement and curve fitting; no image is generated.
public enum LookFitting {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case framing(original: Double, edited: Double)
        case empty

        public var description: String {
            switch self {
            case .framing(let original, let edited):
                return "the two pictures are not the same framing (proportions \(formatNumber(original)) and \(formatNumber(edited))): a pair must be the same shot, uncropped, the same way up"
            case .empty:
                return "a picture is empty"
            }
        }
    }

    /// Where each channel curve gets a control point.
    static let fitInputs: [Double] = [0, 0.05, 0.12, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.88, 0.94, 0.98, 1]
    static let sampleGrid = 160
    static let saturationCandidates: [Double] = Array(stride(from: -60.0, through: 60.0, by: 4.0))

    /// The look that turns `original` into `edited`: for every channel, what each value became
    /// (the median over the picture), as a curve; then the saturation that best matches the rest.
    public static func fit(original: PixelBuffer, edited: PixelBuffer) throws -> LookFit {
        guard original.width > 0, original.height > 0, edited.width > 0, edited.height > 0 else { throw Failure.empty }
        guard abs(original.aspect - edited.aspect) / edited.aspect < 0.03 else {
            throw Failure.framing(original: (original.aspect * 1000).rounded() / 1000, edited: (edited.aspect * 1000).rounded() / 1000)
        }
        let pairs = samples(original, edited)
        var curves: [String: [[Double]]] = [:]
        for (channel, name) in ["red", "green", "blue"].enumerated() {
            let values = pairs.map { ($0.0[channel], $0.1[channel]) }
            curves[name] = fitCurve(values)
        }
        let source = pairs.map { $0.0 }
        let target = pairs.map { $0.1 }
        let (saturation, error) = bestSaturation(curves: curves, source: source, target: target)
        return LookFit(curves: curves, saturation: saturation, error: (error * 255 * 10).rounded() / 10)
    }

    /// Where a fingerprint samples each channel's distribution.
    public static let matchQuantiles: [Double] = [0, 0.01, 0.04, 0.1, 0.2, 0.35, 0.5, 0.65, 0.8, 0.9, 0.96, 0.99, 1]

    /// The fingerprint of a picture's tone and colour.
    public static func fingerprint(of picture: PixelBuffer) -> StyleFingerprint {
        let colors = grid(picture)
        var quantiles: [String: [Double]] = [:]
        for (channel, name) in ["red", "green", "blue"].enumerated() {
            let sorted = colors.map { $0[channel] }.sorted()
            quantiles[name] = matchQuantiles.map { (quantile(sorted, $0) * 10000).rounded() / 10000 }
        }
        return StyleFingerprint(quantiles: quantiles, colourfulness: colourfulness(colors))
    }

    /// An approximate look from a reference of another scene: each channel of `source` is mapped
    /// so its distribution matches the reference's (the darkest 1% to the darkest 1%, the median to
    /// the median, and so on), then saturation is matched. `strength` 0 is no change, 1 a full match.
    public static func match(source: PixelBuffer, reference: PixelBuffer, strength: Double = 1) throws -> LookFit {
        guard reference.width > 0, reference.height > 0 else { throw Failure.empty }
        return try match(source: source, fingerprint: fingerprint(of: reference), strength: strength)
    }

    /// `match` against a fingerprint kept from an earlier picture.
    public static func match(source: PixelBuffer, fingerprint: StyleFingerprint, strength: Double = 1) throws -> LookFit {
        guard source.width > 0, source.height > 0 else { throw Failure.empty }
        let amount = min(1, max(0, strength))
        let from = grid(source)
        var curves: [String: [[Double]]] = [:]
        for (channel, name) in ["red", "green", "blue"].enumerated() {
            let a = from.map { $0[channel] }.sorted()
            let b = fingerprint.quantiles[name] ?? matchQuantiles
            var points: [[Double]] = []
            for (index, q) in matchQuantiles.enumerated() {
                let x = quantile(a, q)
                let y = x + amount * ((index < b.count ? b[index] : q) - x)
                if let last = points.last, x - last[0] < Specs.minCurveGap { continue }
                points.append([x, y])
            }
            // The ends of the range stay reachable: below the darkest and above the brightest measured value.
            if let first = points.first, first[0] > Specs.minCurveGap { points.insert([0, max(0, first[1] - first[0])], at: 0) }
            if let last = points.last, last[0] < 1 - Specs.minCurveGap { points.append([1, min(1, last[1] + (1 - last[0]))]) }
            curves[name] = tidy(points)
        }
        // Saturation: the reference's colourfulness relative to brightness, after the curves.
        let toned = render(curves: curves, saturation: 0, from)
        let ratio = fingerprint.colourfulness / max(0.001, colourfulness(toned))
        let saturation = min(60, max(-60, (ratio - 1) * 100 * amount)).rounded()
        return LookFit(curves: curves, saturation: saturation, error: nil)
    }

    // MARK: Pieces

    /// The same points of both pictures, by position, on an even grid.
    static func samples(_ a: PixelBuffer, _ b: PixelBuffer) -> [([Double], [Double])] {
        var result: [([Double], [Double])] = []
        let n = sampleGrid
        let rows = max(1, Int((Double(n) / max(a.aspect, 0.01)).rounded()))
        result.reserveCapacity(n * rows)
        for row in 0..<rows {
            for column in 0..<n {
                let x = (Double(column) + 0.5) / Double(n)
                let y = (Double(row) + 0.5) / Double(rows)
                let p = a.color(atX: x, y: y)
                let q = b.color(atX: x, y: y)
                result.append(([p.0, p.1, p.2], [q.0, q.1, q.2]))
            }
        }
        return result
    }

    static func grid(_ picture: PixelBuffer) -> [[Double]] {
        samples(picture, picture).map { $0.0 }
    }

    /// For each control input, the median output of the samples near it; gaps filled from the neighbours.
    static func fitCurve(_ values: [(Double, Double)]) -> [[Double]] {
        let sorted = values.sorted { $0.0 < $1.0 }
        var points: [[Double]] = []
        for x in fitInputs {
            var window = 0.025
            var near: [Double] = []
            while window <= 0.15 {
                near = sorted.filter { abs($0.0 - x) <= window }.map { $0.1 }
                if near.count >= 12 { break }
                window *= 1.6
            }
            if near.count >= 4 {
                near.sort()
                points.append([x, near[near.count / 2]])
            }
        }
        guard points.count >= 2 else { return [[0, 0], [1, 1]] }
        // Beyond the measured range, carry on with the slope of the nearest stretch.
        if points[0][0] > 0 {
            let slope = (points[1][1] - points[0][1]) / max(0.01, points[1][0] - points[0][0])
            points.insert([0, max(0, points[0][1] - slope * points[0][0])], at: 0)
        }
        if let last = points.last, last[0] < 1 {
            let previous = points[points.count - 2]
            let slope = (last[1] - previous[1]) / max(0.01, last[0] - previous[0])
            points.append([1, min(1, last[1] + slope * (1 - last[0]))])
        }
        return tidy(points)
    }

    /// Rising, inside 0 to 1, rounded, and no more points than a curve takes.
    static func tidy(_ input: [[Double]]) -> [[Double]] {
        var points: [[Double]] = []
        for point in input {
            var y = min(1, max(0, point[1]))
            if let last = points.last { y = max(y, last[1]) }
            points.append([(point[0] * 10000).rounded() / 10000, (y * 10000).rounded() / 10000])
        }
        while points.count > Specs.maxCurvePoints { points.remove(at: points.count / 2) }
        return points
    }

    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return q }
        let position = q * Double(sorted.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(sorted.count - 1, low + 1)
        let t = position - Double(low)
        return sorted[low] * (1 - t) + sorted[high] * t
    }

    /// What the tone and colour stages make of these colours, as the engine renders them: the tone
    /// stage as its table, then the colour stage.
    static func render(curves: [String: [[Double]]], saturation: Double, _ colors: [[Double]]) -> [[Double]] {
        guard let state = try? LookFit(curves: curves, saturation: saturation).applied(to: EditingState()) else { return colors }
        let table = ColorPipeline.toneTables(state)
        let size = (table?.count ?? 0) / 3
        let stage = ColorPipeline.colorIsIdentity(state) ? nil : ColorPipeline.ColorStage(state)
        return colors.map { color in
            var rgb = color.map { min(1, max(0, $0)) }
            if let table, size > 1 {
                for channel in 0..<3 {
                    let position = rgb[channel] * Double(size - 1)
                    let low = min(size - 2, Int(position))
                    let t = position - Double(low)
                    rgb[channel] = Double(table[low * 3 + channel]) * (1 - t) + Double(table[(low + 1) * 3 + channel]) * t
                }
            }
            guard let stage else { return rgb }
            var (r, g, b) = (rgb[0], rgb[1], rgb[2])
            stage.apply(&r, &g, &b)
            return [r, g, b]
        }
    }

    static func colourfulness(_ colors: [[Double]]) -> Double {
        var chroma = 0.0
        var brightness = 0.0
        for color in colors {
            chroma += (color.max() ?? 0) - (color.min() ?? 0)
            brightness += ColorPipeline.luma(color[0], color[1], color[2])
        }
        return chroma / max(0.001, brightness)
    }

    /// The saturation that brings the fitted curves closest to the target, and the error left (0 to 1).
    static func bestSaturation(curves: [String: [[Double]]], source: [[Double]], target: [[Double]]) -> (Double, Double) {
        // A few thousand evenly spread samples are plenty to choose a saturation.
        let step = max(1, source.count / 3000)
        let indices = Array(stride(from: 0, to: source.count, by: step))
        let colors = indices.map { source[$0] }
        let wanted = indices.map { target[$0] }
        var best = (saturation: 0.0, error: Double.infinity)
        for saturation in saturationCandidates {
            let rendered = render(curves: curves, saturation: saturation, colors)
            var error = 0.0
            for (got, want) in zip(rendered, wanted) {
                error += abs(got[0] - want[0]) + abs(got[1] - want[1]) + abs(got[2] - want[2])
            }
            error /= Double(colors.count * 3)
            if error < best.error { best = (saturation, error) }
        }
        return best
    }
}
