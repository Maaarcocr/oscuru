import Foundation

/// What the viewfinder's instruments show of one live frame: how its tones are spread, and where
/// it is blown. Measured on a coarse grid, a few samples to a cell, so it costs next to nothing.
public struct FrameStatistics: Equatable, Sendable {
    public static let bins = 48

    /// The share of the frame at each brightness, darkest first.
    public var histogram: [Float]
    /// A coarse map of the frame, row by row from the top-left of the picture as measured: 255
    /// where a colour is blown, 0 elsewhere.
    public var blown: [UInt8]
    public var width: Int
    public var height: Int
    /// The share of the frame that is blown.
    public var blownShare: Double

    public init(histogram: [Float], blown: [UInt8], width: Int, height: Int, blownShare: Double) {
        self.histogram = histogram
        self.blown = blown
        self.width = width
        self.height = height
        self.blownShare = blownShare
    }

    /// A channel at or above this (of 255) has nothing left to record.
    static let limit = 250.0
    /// The map is about this many cells along the frame's long side.
    static let cells = 160

    /// From a frame as a camera's video output delivers it: a plane of luma and, at half its size,
    /// a plane of chroma with Cb and Cr side by side (Rec. 709).
    public static func measure(
        luma: UnsafeRawPointer, lumaRowBytes: Int, chroma: UnsafeRawPointer, chromaRowBytes: Int, width: Int, height: Int, fullRange: Bool
    ) -> FrameStatistics {
        let scale = fullRange ? 1.0 : 255.0 / 219
        let floor = fullRange ? 0.0 : 16
        let chromaScale = fullRange ? 1.0 : 255.0 / 224
        return measure(width: width, height: height) { x, y in
            let level = (Double(luma.load(fromByteOffset: y * lumaRowBytes + x, as: UInt8.self)) - floor) * scale
            let offset = (y / 2) * chromaRowBytes + (x / 2) * 2
            let blue = (Double(chroma.load(fromByteOffset: offset, as: UInt8.self)) - 128) * chromaScale
            let red = (Double(chroma.load(fromByteOffset: offset + 1, as: UInt8.self)) - 128) * chromaScale
            let peak = max(level + 1.5748 * red, level - 0.1873 * blue - 0.4681 * red, level + 1.8556 * blue)
            return (level, peak)
        }
    }

    /// From a picture's own pixels: red, green, blue and a fourth byte, row after row.
    public static func measure(rgba: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int) -> FrameStatistics {
        measure(width: width, height: height) { x, y in
            let offset = y * rowBytes + x * 4
            let red = Double(rgba.load(fromByteOffset: offset, as: UInt8.self))
            let green = Double(rgba.load(fromByteOffset: offset + 1, as: UInt8.self))
            let blue = Double(rgba.load(fromByteOffset: offset + 2, as: UInt8.self))
            return (0.2126 * red + 0.7152 * green + 0.0722 * blue, max(red, green, blue))
        }
    }

    /// `sample` gives a pixel's brightness and its brightest channel, both of 255.
    private static func measure(width: Int, height: Int, sample: (Int, Int) -> (level: Double, peak: Double)) -> FrameStatistics {
        let cell = max(2, max(width, height) / cells)
        let columns = width / cell
        let rows = height / cell
        guard columns > 0, rows > 0 else { return FrameStatistics(histogram: Array(repeating: 0, count: bins), blown: [], width: 0, height: 0, blownShare: 0) }
        var counts = [Int](repeating: 0, count: bins)
        var blown = [UInt8](repeating: 0, count: columns * rows)
        var marked = 0
        // Three samples each way in every cell.
        let offsets = [cell / 6, cell / 2, min(cell - 1, cell * 5 / 6)]
        for row in 0..<rows {
            for column in 0..<columns {
                var over = 0
                for dy in offsets {
                    for dx in offsets {
                        let (level, peak) = sample(column * cell + dx, row * cell + dy)
                        counts[min(bins - 1, max(0, Int(level * Double(bins) / 256)))] += 1
                        if peak >= limit { over += 1 }
                    }
                }
                // Most of the cell, so a speck of light is not a warning.
                if over >= 5 {
                    blown[row * columns + column] = 255
                    marked += 1
                }
            }
        }
        let total = Float(columns * rows * 9)
        return FrameStatistics(
            histogram: counts.map { Float($0) / total }, blown: blown, width: columns, height: rows, blownShare: Double(marked) / Double(columns * rows))
    }
}
