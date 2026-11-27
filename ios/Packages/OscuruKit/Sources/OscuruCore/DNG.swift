import Dispatch
import Foundation

/// The raw picture in a DNG: one sample per photosite of the sensor, behind a repeating pattern of
/// colour filters, with the levels that say what its numbers mean.
public struct RawFrame: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Row after row.
    public var samples: [UInt16]
    /// The sample value of no light: one for the whole picture, or one for each place in the
    /// filter pattern, as the file gives them.
    public var blackLevels: [Double]
    /// The sample value at which a photosite is full.
    public var whiteLevel: Double
    /// The file's noise model, as it gives it: pairs of a variance per unit of signal and a
    /// variance at no signal, on a scale where black is 0 and white is 1. Empty when it has none.
    public var noiseProfile: [Double]
    /// The colour behind each place of the two-by-two filter pattern (0 red, 1 green, 2 blue), in
    /// the order top left, top right, bottom left, bottom right.
    public var cfa: [Int]
    /// How the picture is turned to stand upright, as TIFF says it (1 as it is, 3 half a turn, 6 a
    /// quarter turn clockwise, 8 a quarter turn anticlockwise).
    public var orientation: Int

    public init(
        width: Int, height: Int, samples: [UInt16], blackLevels: [Double] = [0], whiteLevel: Double = 65535, noiseProfile: [Double] = [],
        cfa: [Int] = [0, 1, 1, 2], orientation: Int = 1
    ) {
        self.width = width
        self.height = height
        self.samples = samples
        self.blackLevels = blackLevels
        self.whiteLevel = whiteLevel
        self.noiseProfile = noiseProfile
        self.cfa = cfa.count == 4 && cfa.allSatisfy({ (0...2).contains($0) }) ? cfa : [0, 1, 1, 2]
        self.orientation = orientation
    }

    /// No light, as one number.
    public var blackLevel: Double { blackLevels.isEmpty ? 0 : blackLevels.reduce(0, +) / Double(blackLevels.count) }

    /// No light at the photosite (x, y).
    public func black(_ x: Int, _ y: Int) -> Double {
        blackLevels.count == 4 ? blackLevels[(y & 1) * 2 + (x & 1)] : blackLevel
    }

    /// The colour behind the photosite (x, y): 0 red, 1 green, 2 blue.
    public func colour(_ x: Int, _ y: Int) -> Int { cfa[(y & 1) * 2 + (x & 1)] }
}

/// A raw picture with all three colours at every pixel, linear as the sensor measured them (a
/// "linear raw" DNG, as Apple ProRAW is): what merging frames onto a finer grid than the sensor's
/// gives, since every pixel then has samples of every colour near it.
public struct RGBFrame: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Red, green and blue of each pixel, row after row.
    public var samples: [UInt16]
    public var blackLevel: Double
    public var whiteLevel: Double
    public var noiseProfile: [Double]

    public init(width: Int, height: Int, samples: [UInt16], blackLevel: Double, whiteLevel: Double, noiseProfile: [Double] = []) {
        self.width = width
        self.height = height
        self.samples = samples
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.noiseProfile = noiseProfile
    }
}

/// Reading the raw picture out of a DNG as the iPhone's camera writes it (a Bayer mosaic, in
/// tiles of lossless JPEG or uncompressed), and writing a file that is the same DNG with another
/// raw picture in its place. Everything else in the file is kept byte for byte: the colour
/// matrices, the lens corrections, the capture details and the preview.
public enum DNG {
    public enum Failure: Error, Equatable {
        case notDNG
        /// A DNG this code does not read: what it is.
        case unsupported(String)
        case damaged(String)
    }

    /// The raw picture of a DNG.
    public static func frame(of data: Data) throws -> RawFrame {
        let file = try TIFF(bytes: [UInt8](data))
        let raw = try file.rawDirectory()
        return try file.frame(raw)
    }

    /// The same DNG with `frame` as its raw picture: its samples, uncompressed, and its levels and
    /// noise model. `frame` must have the size of the picture it replaces.
    public static func replacingFrame(of data: Data, with frame: RawFrame) throws -> Data {
        let file = try TIFF(bytes: [UInt8](data))
        let raw = try file.rawDirectory()
        let layout = try file.layout(raw)
        guard frame.width == layout.width, frame.height == layout.height, frame.samples.count == frame.width * frame.height else {
            throw DNG.Failure.unsupported("the new raw picture is not the size of the old one")
        }
        return Data(
            try file.replacing(
                raw, picture: Replacement(width: frame.width, height: frame.height, channels: 1, samples: frame.samples, blackLevels: frame.blackLevels,
                    whiteLevel: frame.whiteLevel, noiseProfile: frame.noiseProfile)))
    }

    /// The same DNG with `frame` in place of its Bayer picture: a linear raw picture of three
    /// colours a pixel, of any size, uncompressed. The colour matrices still apply (its colours are
    /// the camera's own); what describes the filter pattern goes, and what describes the old
    /// picture's pixels (its crop) goes with it. A lens correction given in the old picture's
    /// pixels cannot be carried over, and a file that has one is refused.
    public static func replacingFrame(of data: Data, with frame: RGBFrame) throws -> Data {
        let file = try TIFF(bytes: [UInt8](data))
        let raw = try file.rawDirectory()
        guard frame.samples.count == frame.width * frame.height * 3, frame.width > 0, frame.height > 0 else {
            throw DNG.Failure.unsupported("the new picture's samples are not three a pixel")
        }
        return Data(
            try file.replacing(
                raw, picture: Replacement(width: frame.width, height: frame.height, channels: 3, samples: frame.samples,
                    blackLevels: [frame.blackLevel, frame.blackLevel, frame.blackLevel], whiteLevel: frame.whiteLevel, noiseProfile: frame.noiseProfile)))
    }

    /// A picture to write in place of a DNG's raw picture.
    fileprivate struct Replacement {
        var width: Int
        var height: Int
        /// 1 for a Bayer mosaic, 3 for linear red, green and blue.
        var channels: Int
        var samples: [UInt16]
        var blackLevels: [Double]
        var whiteLevel: Double
        var noiseProfile: [Double]
    }
}

// MARK: - TIFF

private enum Tag {
    static let imageWidth = 256
    static let imageLength = 257
    static let bitsPerSample = 258
    static let compression = 259
    static let photometric = 262
    static let stripOffsets = 273
    static let samplesPerPixel = 277
    static let rowsPerStrip = 278
    static let stripByteCounts = 279
    static let predictor = 317
    static let tileWidth = 322
    static let tileLength = 323
    static let tileOffsets = 324
    static let tileByteCounts = 325
    static let subIFDs = 330
    static let orientation = 274
    static let planarConfiguration = 284
    static let cfaRepeatPatternDim = 33421
    static let cfaPattern = 33422
    static let cfaPlaneColor = 50710
    static let cfaLayout = 50711
    static let blackLevelRepeatDim = 50713
    static let defaultCropOrigin = 50719
    static let defaultCropSize = 50720
    static let activeArea = 50829
    static let maskedAreas = 50830
    static let opcodeList1 = 51008
    static let opcodeList2 = 51009
    static let linearizationTable = 50712
    static let blackLevel = 50714
    static let whiteLevel = 50717
    static let noiseProfile = 51041
}

private struct Entry {
    let tag: Int
    let type: Int
    let count: Int
    /// Where in the file the entry's four-byte value field is.
    let field: Int
    /// Where its values are: in that field when they fit, else where it points.
    let offset: Int

    /// Bytes of one value of each TIFF type.
    static let sizes: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
}

private struct Directory {
    let offset: Int
    let entries: [Entry]
    /// The file position of the four bytes that point to this directory.
    let pointer: Int
    /// What follows it in its chain (0 for nothing).
    let next: Int

    func entry(_ tag: Int) -> Entry? { entries.first { $0.tag == tag } }
}

private struct TIFF {
    let bytes: [UInt8]
    let bigEndian: Bool

    init(bytes: [UInt8]) throws {
        guard bytes.count >= 8 else { throw DNG.Failure.notDNG }
        switch (bytes[0], bytes[1]) {
        case (0x4D, 0x4D): bigEndian = true
        case (0x49, 0x49): bigEndian = false
        default: throw DNG.Failure.notDNG
        }
        self.bytes = bytes
        guard try u16(2) == 42 else { throw DNG.Failure.notDNG }
    }

    func u16(_ at: Int) throws -> Int {
        guard at >= 0, at + 2 <= bytes.count else { throw DNG.Failure.damaged("a value lies outside the file") }
        return bigEndian ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : Int(bytes[at + 1]) << 8 | Int(bytes[at])
    }

    func u32(_ at: Int) throws -> Int {
        guard at >= 0, at + 4 <= bytes.count else { throw DNG.Failure.damaged("a value lies outside the file") }
        let b = (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]), Int(bytes[at + 3]))
        return bigEndian ? b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3 : b.3 << 24 | b.2 << 16 | b.1 << 8 | b.0
    }

    func directory(at offset: Int, pointer: Int) throws -> Directory {
        let count = try u16(offset)
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            let at = offset + 2 + index * 12
            let type = try u16(at + 2)
            let values = try u32(at + 4)
            let size = (Entry.sizes[type] ?? 1) * values
            let where_ = size <= 4 ? at + 8 : try u32(at + 8)
            guard where_ >= 0, where_ + size <= bytes.count else { throw DNG.Failure.damaged("a tag's values lie outside the file") }
            entries.append(Entry(tag: try u16(at), type: type, count: values, field: at + 8, offset: where_))
        }
        return Directory(offset: offset, entries: entries, pointer: pointer, next: try u32(offset + 2 + count * 12))
    }

    /// An entry's values as whole numbers (bytes, shorts and longs).
    func integers(_ entry: Entry) throws -> [Int] {
        try (0..<entry.count).map { index in
            switch entry.type {
            case 1, 6, 7: return Int(bytes[entry.offset + index])
            case 3, 8: return try u16(entry.offset + index * 2)
            case 4, 9, 13: return try u32(entry.offset + index * 4)
            default: throw DNG.Failure.unsupported("tag \(entry.tag) is not a whole number")
            }
        }
    }

    /// An entry's values as numbers, whatever their type.
    func numbers(_ entry: Entry) throws -> [Double] {
        try (0..<entry.count).map { index in
            switch entry.type {
            case 5, 10:
                let numerator = try u32(entry.offset + index * 8)
                let denominator = try u32(entry.offset + index * 8 + 4)
                let signed = entry.type == 10
                let top = signed ? Double(Int32(truncatingIfNeeded: numerator)) : Double(numerator)
                let bottom = signed ? Double(Int32(truncatingIfNeeded: denominator)) : Double(denominator)
                return bottom == 0 ? 0 : top / bottom
            case 11: return Double(Float(bitPattern: UInt32(try u32(entry.offset + index * 4))))
            case 12:
                let high = UInt64(try u32(entry.offset + index * 8 + (bigEndian ? 0 : 4)))
                let low = UInt64(try u32(entry.offset + index * 8 + (bigEndian ? 4 : 0)))
                return Double(bitPattern: high << 32 | low)
            default: return Double(try integers(Entry(tag: entry.tag, type: entry.type, count: 1, field: entry.field, offset: entry.offset + index * (Entry.sizes[entry.type] ?? 1)))[0])
            }
        }
    }

    /// The directory of the raw picture: the one whose samples lie behind colour filters. In an
    /// iPhone's DNG it hangs under the first directory, which is a preview.
    func rawDirectory() throws -> Directory {
        var found: Directory?
        var visited = Set<Int>()
        func search(_ offset: Int, pointer: Int) throws {
            guard found == nil, offset != 0, visited.insert(offset).inserted, visited.count <= 32 else { return }
            let directory = try self.directory(at: offset, pointer: pointer)
            if let photometric = directory.entry(Tag.photometric), try integers(photometric).first == 32803 {
                found = directory
                return
            }
            if let children = directory.entry(Tag.subIFDs) {
                for (index, child) in try integers(children).enumerated() { try search(child, pointer: children.offset + index * 4) }
            }
            try search(directory.next, pointer: offset + 2 + directory.entries.count * 12)
        }
        try search(try u32(4), pointer: 4)
        guard let found else { throw DNG.Failure.unsupported("it has no Bayer picture") }
        return found
    }

    /// Where the raw picture's samples are in the file, and how they are cut up.
    struct Layout {
        var width = 0
        var height = 0
        var pieceWidth = 0
        var pieceHeight = 0
        var offsets: [Int] = []
        var counts: [Int] = []
        var compression = 1
    }

    func layout(_ raw: Directory) throws -> Layout {
        func one(_ tag: Int) throws -> Int? { try raw.entry(tag).flatMap { try integers($0).first } }
        guard let width = try one(Tag.imageWidth), let height = try one(Tag.imageLength), width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw DNG.Failure.unsupported("its raw picture has no usable size")
        }
        guard try one(Tag.samplesPerPixel) ?? 1 == 1, try one(Tag.bitsPerSample) == 16 else {
            throw DNG.Failure.unsupported("its samples are not 16-bit")
        }
        if let pattern = raw.entry(Tag.cfaRepeatPatternDim), try integers(pattern) != [2, 2] { throw DNG.Failure.unsupported("its filter pattern is not two by two") }
        if raw.entry(Tag.linearizationTable) != nil { throw DNG.Failure.unsupported("its samples go through a table") }
        var layout = Layout(width: width, height: height, compression: try one(Tag.compression) ?? 1)
        guard layout.compression == 1 || layout.compression == 7 else { throw DNG.Failure.unsupported("its compression (\(layout.compression)) is not read") }
        if let offsets = raw.entry(Tag.tileOffsets), let counts = raw.entry(Tag.tileByteCounts) {
            layout.pieceWidth = try one(Tag.tileWidth) ?? 0
            layout.pieceHeight = try one(Tag.tileLength) ?? 0
            layout.offsets = try integers(offsets)
            layout.counts = try integers(counts)
        } else if let offsets = raw.entry(Tag.stripOffsets), let counts = raw.entry(Tag.stripByteCounts) {
            layout.pieceWidth = width
            layout.pieceHeight = min(height, try one(Tag.rowsPerStrip) ?? height)
            layout.offsets = try integers(offsets)
            layout.counts = try integers(counts)
        }
        guard layout.pieceWidth > 0, layout.pieceHeight > 0, layout.offsets.count == layout.counts.count else {
            throw DNG.Failure.damaged("its raw picture is not laid out in strips or tiles")
        }
        let across = (width + layout.pieceWidth - 1) / layout.pieceWidth
        let down = (height + layout.pieceHeight - 1) / layout.pieceHeight
        guard layout.offsets.count == across * down else { throw DNG.Failure.damaged("its raw picture has the wrong number of pieces") }
        for (offset, count) in zip(layout.offsets, layout.counts) where offset < 0 || count < 0 || offset + count > bytes.count {
            throw DNG.Failure.damaged("part of its raw picture lies outside the file")
        }
        return layout
    }

    /// The samples of one strip or tile.
    private func piece(at offset: Int, count: Int, compressed: Bool) throws -> [UInt16] {
        try bytes.withUnsafeBufferPointer { (file: UnsafeBufferPointer<UInt8>) -> [UInt16] in
            let piece = UnsafeBufferPointer<UInt8>(rebasing: file[offset..<(offset + count)])
            if compressed { return try LosslessJPEG.decode(piece) }
            var samples = [UInt16](repeating: 0, count: count / 2)
            for index in 0..<samples.count {
                let first = UInt16(piece[index * 2])
                let second = UInt16(piece[index * 2 + 1])
                samples[index] = bigEndian ? first << 8 | second : second << 8 | first
            }
            return samples
        }
    }

    func frame(_ raw: Directory) throws -> RawFrame {
        let layout = try layout(raw)
        var samples = [UInt16](repeating: 0, count: layout.width * layout.height)
        let across: Int = (layout.width + layout.pieceWidth - 1) / layout.pieceWidth
        let compressed = layout.compression == 7
        let failure = FirstFailure()
        samples.withUnsafeMutableBufferPointer { samples in
            let picture = Picture(samples: samples.baseAddress!)
            // The pieces are independent of each other: all at once, each into its own part of the picture.
            DispatchQueue.concurrentPerform(iterations: layout.offsets.count) { index in
                do {
                    // A piece's own samples, row after row; pieces at the right and bottom edges are whole.
                    let decoded: [UInt16] = try piece(at: layout.offsets[index], count: layout.counts[index], compressed: compressed)
                    let left: Int = (index % across) * layout.pieceWidth
                    let top: Int = (index / across) * layout.pieceHeight
                    let columns: Int = min(layout.pieceWidth, layout.width - left)
                    let rows: Int = min(layout.pieceHeight, layout.height - top)
                    guard decoded.count >= (rows - 1) * layout.pieceWidth + columns else { throw DNG.Failure.damaged("a piece of its raw picture is too short") }
                    decoded.withUnsafeBufferPointer { decoded in
                        for row in 0..<rows {
                            let to = picture.samples + (top + row) * layout.width + left
                            to.update(from: decoded.baseAddress! + row * layout.pieceWidth, count: columns)
                        }
                    }
                } catch {
                    failure.record(error)
                }
            }
        }
        if let error = failure.error { throw error }
        let first = try directory(at: try u32(4), pointer: 4)
        let orientation = try (raw.entry(Tag.orientation) ?? first.entry(Tag.orientation)).flatMap { try integers($0).first } ?? 1
        let pattern = try raw.entry(Tag.cfaPattern).map { try integers($0) } ?? [0, 1, 1, 2]
        return RawFrame(
            width: layout.width, height: layout.height, samples: samples,
            blackLevels: try raw.entry(Tag.blackLevel).map { try numbers($0) } ?? [0],
            whiteLevel: try raw.entry(Tag.whiteLevel).flatMap { try numbers($0).first } ?? 65535,
            noiseProfile: try noiseEntry(raw).map { try numbers($0) } ?? [], cfa: pattern, orientation: orientation)
    }

    /// The noise model, which an iPhone's DNG keeps with the raw picture and others with the file.
    private func noiseEntry(_ raw: Directory) throws -> Entry? {
        if let entry = raw.entry(Tag.noiseProfile) { return entry }
        return try directory(at: try u32(4), pointer: 4).entry(Tag.noiseProfile)
    }

    /// The file with `picture` as its raw picture. The raw picture's directory is written again at
    /// the end of the file, describing uncompressed strips written before it; where the
    /// old samples were the end of the file (as an iPhone writes it) they are dropped, otherwise
    /// they stay where they are, unused.
    func replacing(_ raw: Directory, picture frame: DNG.Replacement) throws -> [UInt8] {
        let layout = try layout(raw)
        let linear = frame.channels == 3
        if linear {
            // Lens corrections given in the old picture's own pixels would land in the wrong places.
            if raw.entry(Tag.opcodeList1) != nil || raw.entry(Tag.opcodeList2) != nil {
                throw DNG.Failure.unsupported("its raw picture carries corrections in its own pixels")
            }
            if let area = raw.entry(Tag.activeArea), try integers(area) != [0, 0, layout.height, layout.width] {
                throw DNG.Failure.unsupported("its raw picture has a border")
            }
        }
        // Keep the file up to the old samples when nothing else follows them.
        var keep = bytes.count
        let pieces = zip(layout.offsets, layout.counts).sorted { $0.0 < $1.0 }
        if let first = pieces.first {
            var end = first.0
            var contiguous = true
            for (offset, count) in pieces {
                if offset < end || offset > end + 1 { contiguous = false }
                end = offset + count
            }
            let untouched = raw.entries.allSatisfy { $0.field < first.0 && ($0.offset == $0.field || $0.offset + ($0.count * (Entry.sizes[$0.type] ?? 1)) <= first.0) }
            if contiguous, end >= bytes.count - 1, raw.pointer + 4 <= first.0, untouched { keep = first.0 }
        }
        var output = Array(bytes[0..<keep])
        output.reserveCapacity(keep + frame.samples.count * 2 + 4096)
        func pad() { if output.count % 2 == 1 { output.append(0) } }
        func put16(_ value: Int) { output.append(contentsOf: bigEndian ? [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] : [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
        func put32(_ value: Int) {
            let b = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            output.append(contentsOf: bigEndian ? b : b.reversed())
        }
        func set32(_ value: Int, at position: Int) {
            let b = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            output.replaceSubrange(position..<(position + 4), with: bigEndian ? b : b.reversed())
        }

        // The samples, in strips of about a megabyte, as cameras write them: a decoder may refuse
        // (or fail on) one strip of hundreds of megabytes, which a picture onto a finer grid is.
        pad()
        let strip = output.count
        let rowBytes = frame.width * frame.channels * 2
        let rows = min(frame.height, max(2, (1 << 20) / max(1, rowBytes) / 2 * 2))
        let strips = (frame.height + rows - 1) / rows
        output.append(contentsOf: [UInt8](repeating: 0, count: frame.samples.count * 2))
        output.withUnsafeMutableBufferPointer { out in
            frame.samples.withUnsafeBufferPointer { samples in
                for index in 0..<samples.count {
                    let value = samples[index]
                    out[strip + index * 2] = UInt8(bigEndian ? value >> 8 : value & 0xFF)
                    out[strip + index * 2 + 1] = UInt8(bigEndian ? value & 0xFF : value >> 8)
                }
            }
        }

        // The levels, as fractions over 256 so a level between whole numbers survives.
        pad()
        let blacks = output.count
        for level in frame.blackLevels {
            put32(Int((max(0, level) * 256).rounded()))
            put32(256)
        }
        let white = Int(min(max(frame.whiteLevel, 1), 4_294_967_295).rounded())
        let whites = output.count
        if linear { for _ in 0..<3 { put32(white) } }
        let bits = output.count
        if linear { for _ in 0..<3 { put16(16) } }
        pad()
        let stripOffsets = output.count
        if strips > 1 { for index in 0..<strips { put32(strip + index * rows * rowBytes) } }
        let stripCounts = output.count
        if strips > 1 { for index in 0..<strips { put32(min(rows, frame.height - index * rows) * rowBytes) } }

        // The noise model is changed where it stands: it keeps its place and its length.
        if let noise = try noiseEntry(raw), noise.type == 12, noise.count == frame.noiseProfile.count, noise.offset + noise.count * 8 <= keep {
            for (index, value) in frame.noiseProfile.enumerated() {
                let bits = value.bitPattern
                set32(Int(bits >> 32), at: noise.offset + index * 8 + (bigEndian ? 0 : 4))
                set32(Int(bits & 0xFFFF_FFFF), at: noise.offset + index * 8 + (bigEndian ? 4 : 0))
            }
        }

        // The directory: what it had, but for how the samples are stored and what their levels are.
        var replaced: Set<Int> = [
            Tag.bitsPerSample, Tag.compression, Tag.stripOffsets, Tag.rowsPerStrip, Tag.stripByteCounts, Tag.predictor, Tag.tileWidth, Tag.tileLength,
            Tag.tileOffsets, Tag.tileByteCounts, Tag.blackLevel, Tag.whiteLevel,
        ]
        if linear {
            // A picture of its own size and kind: none of what described the mosaic, or its crop, carries over.
            replaced.formUnion([
                Tag.imageWidth, Tag.imageLength, Tag.photometric, Tag.samplesPerPixel, Tag.planarConfiguration, Tag.cfaRepeatPatternDim, Tag.cfaPattern,
                Tag.cfaPlaneColor, Tag.cfaLayout, Tag.blackLevelRepeatDim, Tag.defaultCropOrigin, Tag.defaultCropSize, Tag.activeArea, Tag.maskedAreas,
            ])
        }
        /// A tag, its type, its count and the four bytes of its value field.
        var records: [(tag: Int, type: Int, count: Int, field: [UInt8])] = try raw.entries.filter { !replaced.contains($0.tag) }.map { entry in
            guard entry.field + 4 <= keep, entry.offset == entry.field || entry.offset + entry.count * (Entry.sizes[entry.type] ?? 1) <= keep else {
                throw DNG.Failure.unsupported("its raw picture's details follow its samples")
            }
            return (entry.tag, entry.type, entry.count, Array(bytes[entry.field..<(entry.field + 4)]))
        }
        func short(_ value: Int) -> [UInt8] { bigEndian ? [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF), 0, 0] : [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), 0, 0] }
        func long(_ value: Int) -> [UInt8] {
            let b = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            return bigEndian ? b : b.reversed()
        }
        records.append(linear ? (Tag.bitsPerSample, 3, 3, long(bits)) : (Tag.bitsPerSample, 3, 1, short(16)))
        records.append((Tag.compression, 3, 1, short(1)))
        records.append((Tag.stripOffsets, 4, strips, long(strips > 1 ? stripOffsets : strip)))
        records.append((Tag.rowsPerStrip, 4, 1, long(rows)))
        records.append((Tag.stripByteCounts, 4, strips, long(strips > 1 ? stripCounts : frame.samples.count * 2)))
        records.append((Tag.blackLevel, 5, frame.blackLevels.count, long(blacks)))
        records.append(linear ? (Tag.whiteLevel, 4, 3, long(whites)) : (Tag.whiteLevel, 4, 1, long(white)))
        if linear {
            records.append((Tag.imageWidth, 4, 1, long(frame.width)))
            records.append((Tag.imageLength, 4, 1, long(frame.height)))
            records.append((Tag.photometric, 3, 1, short(34892)))
            records.append((Tag.samplesPerPixel, 3, 1, short(3)))
            records.append((Tag.planarConfiguration, 3, 1, short(1)))
        }
        records.sort { $0.tag < $1.tag }

        pad()
        let directory = output.count
        put16(records.count)
        for record in records {
            put16(record.tag)
            put16(record.type)
            put32(record.count)
            output.append(contentsOf: record.field)
        }
        put32(raw.next < keep ? raw.next : 0)
        set32(directory, at: raw.pointer)
        return output
    }
}

/// Where a picture's pieces are written, each to its own samples.
private struct Picture: @unchecked Sendable {
    let samples: UnsafeMutablePointer<UInt16>
}

/// The first thing that went wrong among pieces read at once.
private final class FirstFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Error?

    var error: Error? { lock.withLock { first } }

    func record(_ error: Error) {
        lock.withLock { if first == nil { first = error } }
    }
}

// MARK: - Lossless JPEG

/// The lossless JPEG of DNG raw data (ITU T.81, process 14): each sample is written as its
/// difference from a prediction made from its neighbours, in a Huffman code.
enum LosslessJPEG {
    /// The samples of one picture, row after row, each row's components side by side.
    static func decode(_ input: UnsafeBufferPointer<UInt8>) throws -> [UInt16] {
        func byte(_ position: Int) throws -> Int {
            guard position >= 0, position < input.count else { throw DNG.Failure.damaged("a compressed piece ends early") }
            return Int(input[position])
        }
        func word(_ position: Int) throws -> Int { try byte(position) << 8 | byte(position + 1) }
        guard try word(0) == 0xFFD8 else { throw DNG.Failure.damaged("a compressed piece is not a JPEG") }
        var at = 2

        var tables = [[UInt16]](repeating: [], count: 4)
        var precision = 0
        var rows = 0
        var columns = 0
        var components: [Int] = []
        var tableOf: [Int: Int] = [:]
        var restartInterval = 0
        var predictor = 1
        var transform = 0
        var scan = false
        while !scan {
            guard try byte(at) == 0xFF else { throw DNG.Failure.damaged("a compressed piece has no marker where one belongs") }
            let marker = try byte(at + 1)
            if marker == 0xFF {
                at += 1
                continue
            }
            let length = try word(at + 2)
            let body = at + 4
            switch marker {
            case 0xC4:
                var position = body
                while position < at + 2 + length {
                    let slot = try byte(position) & 0x0F
                    guard slot < 4 else { throw DNG.Failure.damaged("a compressed piece names a code table that cannot be") }
                    var lengths: [Int] = []
                    for index in 0..<16 { lengths.append(try byte(position + 1 + index)) }
                    position += 17
                    // Every 16-bit run of input, to the length of the code it starts with and that code's symbol.
                    var table = [UInt16](repeating: 0, count: 65536)
                    var code = 0
                    for bits in 1...16 {
                        for _ in 0..<lengths[bits - 1] {
                            let symbol = try byte(position)
                            position += 1
                            guard code < (1 << bits) else { throw DNG.Failure.damaged("a compressed piece has a code table that cannot be") }
                            let first = code << (16 - bits)
                            let entry = UInt16(bits << 8 | symbol)
                            for index in first..<(first + (1 << (16 - bits))) { table[index] = entry }
                            code += 1
                        }
                        code <<= 1
                    }
                    tables[slot] = table
                }
            case 0xC3:
                precision = try byte(body)
                rows = try word(body + 1)
                columns = try word(body + 3)
                let count = try byte(body + 5)
                components = try (0..<count).map { try byte(body + 6 + $0 * 3) }
            case 0xDD:
                restartInterval = try word(body)
            case 0xDA:
                let count = try byte(body)
                for index in 0..<count { tableOf[try byte(body + 1 + index * 2)] = try byte(body + 2 + index * 2) >> 4 }
                predictor = try byte(body + 1 + count * 2)
                transform = try byte(body + 3 + count * 2) & 0x0F
                scan = true
            case 0xC0, 0xC1, 0xC2:
                throw DNG.Failure.unsupported("a piece of its raw picture is not lossless JPEG")
            default:
                break
            }
            at += 2 + length
        }
        guard precision >= 2, precision <= 16, rows > 0, columns > 0, !components.isEmpty, components.count <= 4, (1...7).contains(predictor), transform < precision else {
            throw DNG.Failure.damaged("a compressed piece does not describe a picture")
        }
        // Every component's code table, one after another.
        let planes = components.count
        var codes = [UInt16](repeating: 0, count: planes * 65536)
        for (plane, component) in components.enumerated() {
            guard let slot = tableOf[component], slot < 4, !tables[slot].isEmpty else { throw DNG.Failure.damaged("a compressed piece lacks a code table") }
            codes.replaceSubrange((plane * 65536)..<((plane + 1) * 65536), with: tables[slot])
        }

        let rowLength = columns * planes
        var output = [UInt16](repeating: 0, count: rowLength * rows)
        var bits = Bits(input: input.baseAddress!, count: input.count, position: at)
        let start = 1 << (precision - transform - 1)
        var sinceRestart = 0
        var restartRow = 0
        var broken = false
        codes.withUnsafeBufferPointer { codes in
            output.withUnsafeMutableBufferPointer { out in
                let codes = codes.baseAddress!
                let out = out.baseAddress!
                for row in 0..<rows {
                    for column in 0..<columns {
                        if restartInterval > 0, sinceRestart == restartInterval {
                            // A restart: the bits start again at a byte, after a marker, and prediction starts afresh.
                            bits.restart()
                            sinceRestart = 0
                            restartRow = row
                        }
                        sinceRestart += 1
                        let fresh = restartInterval > 0 && sinceRestart == 1
                        for plane in 0..<planes {
                            let index = row * rowLength + column * planes + plane
                            let predicted: Int
                            if fresh || (row == restartRow && column == 0) {
                                predicted = start
                            } else if row == restartRow {
                                predicted = Int(out[index - planes])
                            } else if column == 0 {
                                predicted = Int(out[index - rowLength])
                            } else if predictor == 1 {
                                predicted = Int(out[index - planes])
                            } else {
                                let left = Int(out[index - planes])
                                let above = Int(out[index - rowLength])
                                let corner = Int(out[index - rowLength - planes])
                                switch predictor {
                                case 2: predicted = above
                                case 3: predicted = corner
                                case 4: predicted = left + above - corner
                                case 5: predicted = left + ((above - corner) >> 1)
                                case 6: predicted = above + ((left - corner) >> 1)
                                default: predicted = (left + above) >> 1
                                }
                            }
                            bits.fill()
                            let entry = codes[plane << 16 | Int(bits.buffer >> 48)]
                            let length = Int(entry >> 8)
                            let size = Int(entry & 0xFF)
                            if length == 0 || size > 16 { broken = true }
                            bits.buffer <<= UInt64(length)
                            bits.held -= length
                            var difference = 0
                            if size == 16 {
                                difference = 32768
                            } else if size > 0 {
                                // At least 41 bits are still held, more than any size.
                                let value = Int(bits.buffer >> UInt64(64 - size))
                                bits.buffer <<= UInt64(size)
                                bits.held -= size
                                difference = value < (1 << (size - 1)) ? value - (1 << size) + 1 : value
                            }
                            out[index] = UInt16(truncatingIfNeeded: predicted + difference)
                        }
                    }
                    if broken { break }
                }
                if transform > 0 { for index in 0..<(rowLength * rows) { out[index] <<= UInt16(transform) } }
            }
        }
        if broken { throw DNG.Failure.damaged("a compressed piece has bits that are no code") }
        return output
    }

    /// A JPEG's entropy-coded bits, most significant first, with its stuffed zero bytes taken out.
    private struct Bits {
        let input: UnsafePointer<UInt8>
        let count: Int
        var position: Int
        var buffer: UInt64 = 0
        var held = 0

        /// Tops the buffer up to more than 56 bits; past the data's end, with zeros.
        @inline(__always)
        mutating func fill() {
            while held <= 56 {
                var next: UInt64 = 0
                if position < count {
                    let value = input[position]
                    if value != 0xFF {
                        next = UInt64(value)
                        position += 1
                    } else if position + 1 < count, input[position + 1] == 0 {
                        // FF 00 is a data byte of FF; FF and anything else is a marker, where the data ends.
                        next = 0xFF
                        position += 2
                    }
                }
                buffer |= next << UInt64(56 - held)
                held += 8
            }
        }

        /// Goes on after the next restart marker, at a whole byte.
        mutating func restart() {
            held = 0
            buffer = 0
            // The buffer may have read ahead to the marker, never past it.
            while position + 1 < count, !(input[position] == 0xFF && (0xD0...0xD7).contains(input[position + 1])) { position += 1 }
            position += 2
        }
    }
}
