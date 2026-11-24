import Foundation

/// Snapping a mask's edge to the edges in the photo: the guided filter (He, Sun and Tang, 2010),
/// with the photo's luminance as the guide, then a firmer edge. Where the photo is flat the mask
/// keeps its shape; where the photo has an edge, the mask's change moves onto it. Plain arithmetic
/// on grey values, rows from the top.
public enum EdgeSnap {
    /// `mask` made to follow `guide`. Both are `width` × `height` values from 0 to 1. `radius` is
    /// the window's half size in pixels; `epsilon` how strong an edge in the guide must be to count.
    public static func guided(mask: [Float], guide: [Float], width: Int, height: Int, radius: Int, epsilon: Float) -> [Float] {
        let count = width * height
        guard count > 0, mask.count == count, guide.count == count else { return mask }
        func mean(_ values: [Float]) -> [Float] { boxMean(values, width: width, height: height, radius: radius) }
        let meanGuide = mean(guide)
        let meanMask = mean(mask)
        let guideSquared = mean(zip(guide, guide).map(*))
        let guideMask = mean(zip(guide, mask).map(*))
        var a = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let variance = guideSquared[index] - meanGuide[index] * meanGuide[index]
            let covariance = guideMask[index] - meanGuide[index] * meanMask[index]
            a[index] = covariance / (variance + epsilon)
            b[index] = meanMask[index] - a[index] * meanGuide[index]
        }
        let meanA = mean(a)
        let meanB = mean(b)
        return (0..<count).map { meanA[$0] * guide[$0] + meanB[$0] }
    }

    /// The mean of each pixel's square window, clipped at the borders, from a summed-area table.
    static func boxMean(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let stride = width + 1
        var table = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += Double(values[y * width + x])
                table[(y + 1) * stride + x + 1] = table[y * stride + x + 1] + row
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let top = max(0, y - radius)
            let bottom = min(height - 1, y + radius)
            for x in 0..<width {
                let left = max(0, x - radius)
                let right = min(width - 1, x + radius)
                let sum = table[(bottom + 1) * stride + right + 1] - table[top * stride + right + 1] - table[(bottom + 1) * stride + left] + table[top * stride + left]
                out[y * width + x] = Float(sum / Double((bottom - top + 1) * (right - left + 1)))
            }
        }
        return out
    }

    /// A mask snapped to the guide's edges with `strength` from 0 to 1: the stronger, the wider
    /// the window an edge can move across and the firmer the edge it ends with.
    public static func snap(mask: [Float], guide: [Float], width: Int, height: Int, strength: Double) -> [Float] {
        let strength = min(1, max(0, strength))
        guard strength > 0 else { return mask }
        let radius = max(1, Int(((0.006 + 0.03 * strength) * Double(max(width, height))).rounded()))
        let filtered = guided(mask: mask, guide: guide, width: width, height: height, radius: radius, epsilon: 0.001)
        let gain = Float(1 + 2 * strength)
        return filtered.map { min(1, max(0, 0.5 + ($0 - 0.5) * gain)) }
    }
}
