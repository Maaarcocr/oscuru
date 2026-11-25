import Foundation

/// What a lens lets the photographer set: the range of each value an exposure is made of.
public struct ExposureLimits: Equatable, Sendable {
    /// F-numbers. One value when the lens's aperture is fixed, as on most iPhone lenses.
    public var aperture: ClosedRange<Double>
    /// The stops the lens recommends between its widest aperture and its smallest.
    public var apertureStops: [Double]
    /// Seconds.
    public var time: ClosedRange<Double>
    public var iso: ClosedRange<Double>
    /// Whether the lens can be focused by hand.
    public var focus: Bool

    public init(
        aperture: ClosedRange<Double> = 1.8...1.8, apertureStops: [Double] = [], time: ClosedRange<Double> = (1.0 / 8000)...1,
        iso: ClosedRange<Double> = 50...3200, focus: Bool = true
    ) {
        self.aperture = aperture
        self.apertureStops = apertureStops
        self.time = time
        self.iso = iso
        self.focus = focus
    }

    public var apertureIsFixed: Bool { aperture.upperBound / aperture.lowerBound < 1.02 }
    /// The values each dial stops at, smallest first.
    public var apertures: [Double] { ExposureScale.apertures(in: aperture, recommended: apertureStops) }
    public var times: [Double] { ExposureScale.times(in: time) }
    public var isos: [Double] { ExposureScale.isos(in: iso) }
}

/// What the camera is doing now.
public struct ExposureReading: Equatable, Sendable {
    public var aperture: Double
    /// Seconds.
    public var time: Double
    public var iso: Double
    /// How far the picture is from what the camera's meter would choose, in stops: above zero is brighter.
    public var offset: Double
    /// Where the lens is focused: 0 is its nearest, 1 its farthest.
    public var focus: Double

    public init(aperture: Double = 1.8, time: Double = 1.0 / 60, iso: Double = 100, offset: Double = 0, focus: Double = 1) {
        self.aperture = aperture
        self.time = time
        self.iso = iso
        self.offset = offset
        self.focus = focus
    }
}

/// What the photographer has set. A value left nil is the camera's to choose.
public struct ExposureSettings: Equatable, Sendable {
    public var aperture: Double?
    /// Seconds.
    public var time: Double?
    public var iso: Double?
    /// Compensation, in stops, for whatever is left to the camera.
    public var bias: Double

    public init(aperture: Double? = nil, time: Double? = nil, iso: Double? = nil, bias: Double = 0) {
        self.aperture = aperture
        self.time = time
        self.iso = iso
        self.bias = bias
    }

    /// Everything is left to the camera.
    public var isAutomatic: Bool { aperture == nil && time == nil && iso == nil }

    /// Nothing is left to the camera, on a lens with these limits: compensation has nothing to act on.
    public func isManual(with limits: ExposureLimits) -> Bool {
        time != nil && iso != nil && (aperture != nil || limits.apertureIsFixed)
    }

    /// These settings as a lens with these limits can take them: each set value inside its range,
    /// and no aperture set on a lens whose aperture is fixed.
    public func clamped(to limits: ExposureLimits) -> ExposureSettings {
        func inside(_ value: Double?, _ range: ClosedRange<Double>) -> Double? { value.map { min(max($0, range.lowerBound), range.upperBound) } }
        return ExposureSettings(
            aperture: limits.apertureIsFixed ? nil : inside(aperture, limits.aperture), time: inside(time, limits.time), iso: inside(iso, limits.iso),
            bias: bias)
    }
}

/// The values a camera's dials stop at, a third of a stop apart, and how a camera writes them.
public enum ExposureScale {
    private static let seconds: [Double] = [0.3, 0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30]
    private static let fractions: [Double] = [
        4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200,
        4000, 5000, 6400, 8000, 10000, 12500, 16000, 20000, 25000, 32000, 40000, 50000, 64000, 80000, 100000,
    ]
    private static let wholeSeconds: Set<Double> = [0.5, 1, 2, 4, 8, 15, 30]
    private static let wholeFractions: Set<Double> = [4, 8, 15, 30, 60, 125, 250, 500, 1000, 2000, 4000, 8000, 16000, 32000, 64000]
    private static let sensitivities: [Double] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000,
        10000, 12800, 16000, 20000, 25600, 32000, 40000, 51200, 64000, 80000, 102400,
    ]
    private static let wholeSensitivities: Set<Double> = [25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200, 102400]
    private static let numbers: [Double] = [1, 1.1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16]

    /// Every shutter time a camera names, shortest first.
    private static let allTimes: [Double] = fractions.reversed().map { 1 / $0 } + seconds

    /// The shutter times inside `range`, shortest first, in seconds.
    public static func times(in range: ClosedRange<Double>) -> [Double] { stops(allTimes, in: range) }

    public static func isos(in range: ClosedRange<Double>) -> [Double] { stops(sensitivities, in: range) }

    /// The apertures inside `range`, widest first: the lens's own stops, with the usual thirds between.
    public static func apertures(in range: ClosedRange<Double>, recommended: [Double]) -> [Double] {
        guard range.upperBound / range.lowerBound >= 1.02 else { return [range.lowerBound] }
        var stops = recommended.filter { $0 >= range.lowerBound * 0.995 && $0 <= range.upperBound * 1.005 }
        for candidate in [range.lowerBound, range.upperBound] + numbers.filter({ $0 > range.lowerBound && $0 < range.upperBound }) {
            if !stops.contains(where: { abs(log2($0 / candidate)) < 0.08 }) { stops.append(candidate) }
        }
        return stops.sorted()
    }

    /// The named values inside the range, and the range's own ends where no named value is near them.
    private static func stops(_ named: [Double], in range: ClosedRange<Double>) -> [Double] {
        var stops = named.filter { $0 >= range.lowerBound * 0.995 && $0 <= range.upperBound * 1.005 }
        for end in [range.lowerBound, range.upperBound] where !stops.contains(where: { abs(log2($0 / end)) < 0.12 }) { stops.append(end) }
        return stops.sorted()
    }

    /// The stop nearest `value`, counted in stops rather than in numbers.
    public static func nearest(_ value: Double, in stops: [Double]) -> Double {
        guard value > 0 else { return stops.first ?? value }
        return stops.min { abs(log2($0 / value)) < abs(log2($1 / value)) } ?? value
    }

    /// The stop `count` places along from the one nearest `value`, stopping at the ends.
    public static func step(_ value: Double, by count: Int, in stops: [Double]) -> Double {
        let current = nearest(value, in: stops)
        guard let index = stops.firstIndex(of: current) else { return value }
        return stops[min(max(index + count, 0), stops.count - 1)]
    }

    /// Whether a camera would print this stop on its dial: the whole stops, not the thirds between.
    public static func isWholeTime(_ seconds: Double) -> Bool {
        seconds >= 0.28 ? wholeSeconds.contains(nearest(seconds, in: Self.seconds)) : wholeFractions.contains(nearest(1 / seconds, in: fractions))
    }

    public static func isWholeISO(_ iso: Double) -> Bool { wholeSensitivities.contains(nearest(iso, in: sensitivities)) }

    /// "1/60", "1/47", "0.5″", "2″": a shutter time as a camera shows it. A time close to a named
    /// one takes its name; the camera's own choices between stops are written to two figures.
    public static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "–" }
        if seconds >= 0.28 {
            let named = nearest(seconds, in: Self.seconds)
            let value = abs(log2(named / seconds)) < 0.09 ? named : (seconds * 10).rounded() / 10
            return (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) + "″"
        }
        let denominator = 1 / seconds
        let named = nearest(denominator, in: fractions)
        if abs(log2(named / denominator)) < 0.09 { return "1/\(Int(named))" }
        let magnitude = pow(10, floor(log10(denominator)) - 1)
        return "1/\(Int((denominator / magnitude).rounded() * magnitude))"
    }

    /// "100", "640", "55": an ISO as a camera shows it.
    public static func isoText(_ iso: Double) -> String {
        guard iso.isFinite, iso > 0 else { return "–" }
        let named = nearest(iso, in: sensitivities)
        if abs(log2(named / iso)) < 0.05 { return String(Int(named)) }
        let step: Double = iso < 100 ? 1 : iso < 1000 ? 10 : 100
        return String(Int((iso / step).rounded() * step))
    }

    /// "1.8", "4", "11": an f-number without its ƒ.
    public static func apertureText(_ number: Double) -> String {
        guard number.isFinite, number > 0 else { return "–" }
        let value = number >= 9.95 ? number.rounded() : (number * 10).rounded() / 10
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// "+0.7", "−1.3", "±0": stops, as a camera shows them.
    public static func stopsText(_ stops: Double) -> String {
        guard stops.isFinite else { return "±0" }
        let value = (abs(stops) * 10).rounded() / 10
        if value == 0 { return "±0" }
        return (stops > 0 ? "+" : "−") + String(format: "%.1f", value)
    }
}
