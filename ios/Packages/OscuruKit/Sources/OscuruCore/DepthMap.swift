import Foundation

/// How far each part of a photo is, from its nearest part (0) to its farthest (1), on a small grid
/// over the whole picture (rows from the top). The phone estimates it from the picture alone, so it
/// is relative: it orders things by distance, it does not measure metres.
public struct DepthMap: Equatable, Sendable {
    public let values: [Float]
    public let width: Int
    public let height: Int

    /// From a depth model's output, which is larger the nearer something is (inverse depth). The
    /// nearest and farthest hundredth of the picture are clipped, so a stray pixel cannot squeeze the
    /// scale; everything in between keeps the model's spacing.
    public init(inverseDepth: [Float], width: Int, height: Int) {
        precondition(inverseDepth.count == width * height)
        self.width = width
        self.height = height
        let finite = inverseDepth.filter(\.isFinite).sorted()
        let low = finite.isEmpty ? 0 : finite[Int(Double(finite.count - 1) * 0.01)]
        let high = finite.isEmpty ? 0 : finite[Int(Double(finite.count - 1) * 0.99)]
        // A picture with nothing nearer or farther than anything else is all middle distance.
        guard high - low > 1e-6 * max(1, abs(high)) else {
            values = [Float](repeating: 0.5, count: inverseDepth.count)
            return
        }
        values = inverseDepth.map { value in
            guard value.isFinite else { return 1 }
            return 1 - min(1, max(0, (value - low) / (high - low)))
        }
    }

    /// The band's weight at every point, as 8-bit greys (rows from the top); without a band, the
    /// distances themselves.
    public func greys(in band: ValueRange?) -> [UInt8] {
        values.map { value in
            let weight = band.map { $0.weight(Double(value)) } ?? Double(value)
            return UInt8(max(0, min(255, (weight * 255).rounded())))
        }
    }
}
