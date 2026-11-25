import Foundation
import XCTest

@testable import OscuruCore

final class DNGTests: XCTestCase {
    /// A mosaic with detail, noise-like texture and its full range of values.
    static func mosaic(width: Int, height: Int, seed: UInt64 = 1) -> [UInt16] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (0..<(width * height)).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let x = index % width, y = index / width
            let smooth = 600 + 40 * (x / 8) + 25 * (y / 4)
            let rough = Int(state >> 54) - 512
            // A few samples at the ends of the range, where a difference needs all sixteen bits.
            if index % 977 == 0 { return index % 2 == 0 ? 0 : 65535 }
            return UInt16(clamping: smooth + rough)
        }
    }

    func testCompressedPiecesDecodeToTheSamplesWritten() throws {
        for (width, height) in [(64, 48), (126, 34)] {
            let samples = Self.mosaic(width: width, height: height)
            for predictor in 1...7 {
                let jpeg = TestJPEG.encode(samples, width: width, height: height, predictor: predictor)
                let decoded = try jpeg.withUnsafeBufferPointer { try LosslessJPEG.decode($0) }
                XCTAssertEqual(decoded, samples, "predictor \(predictor), \(width)×\(height)")
            }
        }
        XCTAssertThrowsError(try [UInt8]([0xFF, 0xD8, 0xFF]).withUnsafeBufferPointer { try LosslessJPEG.decode($0) })
    }

    func testARawPictureIsReadFromTilesAndFromStrips() throws {
        let width = 96, height = 64
        let samples = Self.mosaic(width: width, height: height, seed: 7)
        for bigEndian in [true, false] {
            for compressed in [true, false] {
                let file = TestDNG.make(samples: samples, width: width, height: height, tile: (40, 24), compressed: compressed, bigEndian: bigEndian)
                let frame = try DNG.frame(of: file)
                XCTAssertEqual(frame.width, width)
                XCTAssertEqual(frame.height, height)
                XCTAssertEqual(frame.samples, samples, "tiles, \(compressed ? "compressed" : "plain"), \(bigEndian ? "big" : "little")-endian")
                XCTAssertEqual(frame.blackLevels, [528])
                XCTAssertEqual(frame.whiteLevel, 4095)
                XCTAssertEqual(frame.noiseProfile, [2e-5, 3e-7])
            }
        }
        XCTAssertThrowsError(try DNG.frame(of: Data([1, 2, 3]))) { XCTAssertEqual($0 as? DNG.Failure, .notDNG) }
    }

    func testAnotherRawPictureTakesItsPlaceAndTheRestOfTheFileStays() throws {
        let width = 96, height = 64
        let old = Self.mosaic(width: width, height: height, seed: 3)
        let new = Self.mosaic(width: width, height: height, seed: 9)
        for bigEndian in [true, false] {
            let file = TestDNG.make(samples: old, width: width, height: height, tile: (40, 24), compressed: true, bigEndian: bigEndian)
            let merged = RawFrame(width: width, height: height, samples: new, blackLevels: [8448], whiteLevel: 65520, noiseProfile: [2.5e-6, 3.75e-8])
            let written = try DNG.replacingFrame(of: file, with: merged)
            XCTAssertEqual(try DNG.frame(of: written), merged, "it reads back as written")
            // The old samples were the end of the file, so they are gone rather than left behind.
            XCTAssertLessThan(written.count, TestDNG.rawStart(of: file) + new.count * 2 + 400)
            XCTAssertEqual(written.prefix(TestDNG.rawStart(of: file) - 16).dropFirst(64), file.prefix(TestDNG.rawStart(of: file) - 16).dropFirst(64), "what came before is untouched, but for the noise model")
            XCTAssertEqual(TestDNG.cameraModel(of: written), "Test camera", "the first directory still says what it said")
        }
        let wrongSize = RawFrame(width: 8, height: 8, samples: [UInt16](repeating: 0, count: 64))
        let file = TestDNG.make(samples: old, width: width, height: height, tile: (40, 24), compressed: true, bigEndian: true)
        XCTAssertThrowsError(try DNG.replacingFrame(of: file, with: wrongSize))
    }

    /// With real iPhone DNGs at hand (OSCURU_DNG_SAMPLES names a folder of `name.dng` beside
    /// `name.raw16`, the same picture decoded by another reader as little-endian 16-bit samples),
    /// every sample must match, and a file written back must read the same.
    func testRealFilesDecodeAsAnotherReaderDecodesThem() throws {
        guard let folder = ProcessInfo.processInfo.environment["OSCURU_DNG_SAMPLES"] else { throw XCTSkip("no sample files here") }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".raw16") }.map { String($0.dropLast(6)) }
        XCTAssertFalse(names.isEmpty)
        for name in names.sorted() {
            let file = try Data(contentsOf: URL(fileURLWithPath: "\(folder)/\(name).dng"))
            let expected = try Data(contentsOf: URL(fileURLWithPath: "\(folder)/\(name).raw16"))
            let started = Date()
            let frame = try DNG.frame(of: file)
            print("\(name): \(frame.width)×\(frame.height), black \(frame.blackLevels), white \(frame.whiteLevel), noise \(frame.noiseProfile), read in \(Date().timeIntervalSince(started)) s")
            XCTAssertEqual(frame.samples.count * 2, expected.count)
            let other = [UInt8](expected)
            var different = 0
            for index in 0..<frame.samples.count {
                let low = UInt16(other[index * 2])
                let high = UInt16(other[index * 2 + 1])
                if frame.samples[index] != (high << 8 | low) { different += 1 }
            }
            XCTAssertEqual(different, 0, "\(name) decodes sample for sample")
            let written = try DNG.replacingFrame(of: file, with: frame)
            XCTAssertEqual(try DNG.frame(of: written), frame)
            try written.write(to: URL(fileURLWithPath: "\(folder)/\(name).rewritten.dng"))
        }
    }
}

/// A lossless JPEG writer for tests: two components side by side, as the iPhone writes Bayer rows.
enum TestJPEG {
    static func encode(_ samples: [UInt16], width: Int, height: Int, predictor: Int = 1) -> [UInt8] {
        let columns = width / 2
        var out: [UInt8] = [0xFF, 0xD8]
        // One code table: all seventeen sizes, five bits each.
        out += [0xFF, 0xC4, 0, 36, 0x00, 0, 0, 0, 0, 17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + (0...16).map { UInt8($0) }
        out += [0xFF, 0xC3, 0, 14, 16, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(columns >> 8), UInt8(columns & 0xFF), 2, 0, 0x11, 0, 1, 0x11, 0]
        out += [0xFF, 0xDA, 0, 10, 2, 0, 0x00, 1, 0x00, UInt8(predictor), 0, 0]
        var buffer: UInt64 = 0
        var held = 0
        func put(_ value: Int, _ bits: Int) {
            guard bits > 0 else { return }
            buffer = buffer << UInt64(bits) | UInt64(value & ((1 << bits) - 1))
            held += bits
            while held >= 8 {
                let byte = UInt8(buffer >> UInt64(held - 8) & 0xFF)
                out.append(byte)
                if byte == 0xFF { out.append(0) }
                held -= 8
            }
        }
        for row in 0..<height {
            for column in 0..<columns {
                for plane in 0..<2 {
                    let index = row * width + column * 2 + plane
                    let predicted: Int
                    if row == 0 && column == 0 {
                        predicted = 32768
                    } else if row == 0 {
                        predicted = Int(samples[index - 2])
                    } else if column == 0 {
                        predicted = Int(samples[index - width])
                    } else {
                        let left = Int(samples[index - 2]), above = Int(samples[index - width]), corner = Int(samples[index - width - 2])
                        switch predictor {
                        case 1: predicted = left
                        case 2: predicted = above
                        case 3: predicted = corner
                        case 4: predicted = left + above - corner
                        case 5: predicted = left + ((above - corner) >> 1)
                        case 6: predicted = above + ((left - corner) >> 1)
                        default: predicted = (left + above) >> 1
                        }
                    }
                    // The difference, modulo 65536, as a number from -32767 to 32768.
                    var difference = (Int(samples[index]) - predicted) & 0xFFFF
                    if difference > 32768 { difference -= 65536 }
                    let size = difference == 0 ? 0 : difference == 32768 ? 16 : Int.bitWidth - abs(difference).leadingZeroBitCount
                    put(size, 5)
                    if size > 0, size < 16 { put(difference < 0 ? difference + (1 << size) - 1 : difference, size) }
                }
            }
        }
        if held > 0 { put(0x7F, 8 - held) }
        out += [0xFF, 0xD9]
        return out
    }
}

/// A DNG laid out as the iPhone's camera lays one out: a first directory for a preview, the raw
/// picture in a directory under it, its samples in tiles at the end of the file.
enum TestDNG {
    static func make(samples: [UInt16], width: Int, height: Int, tile: (Int, Int), compressed: Bool, bigEndian: Bool) -> Data {
        var out: [UInt8] = []
        func put16(_ value: Int) { out += bigEndian ? [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] : [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
        func put32(_ value: Int) {
            let b = [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
            out += bigEndian ? b : b.reversed()
        }
        func put64(_ value: Double) {
            put32(Int(value.bitPattern >> (bigEndian ? 32 : 0) & 0xFFFF_FFFF))
            put32(Int(value.bitPattern >> (bigEndian ? 0 : 32) & 0xFFFF_FFFF))
        }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) {
            put16(tag)
            put16(type)
            put32(count)
            if type == 3, count == 1 { put16(value); put16(0) } else { put32(value) }
        }
        // The tiles, cut from the picture; tiles at the edges are whole, padded with what is beside them.
        let across = (width + tile.0 - 1) / tile.0, down = (height + tile.1 - 1) / tile.1
        var tiles: [[UInt8]] = []
        for index in 0..<(across * down) {
            var piece = [UInt16](repeating: 0, count: tile.0 * tile.1)
            for y in 0..<tile.1 {
                for x in 0..<tile.0 {
                    let fromX = min(width - 1, (index % across) * tile.0 + x), fromY = min(height - 1, (index / across) * tile.1 + y)
                    piece[y * tile.0 + x] = samples[fromY * width + fromX]
                }
            }
            tiles.append(compressed ? TestJPEG.encode(piece, width: tile.0, height: tile.1) : piece.flatMap { bigEndian ? [UInt8($0 >> 8), UInt8($0 & 0xFF)] : [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        }
        // Header, the first directory (a preview's, here with only what the tests look at) and its values.
        out += bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        put16(42)
        put32(8)
        let model = Array("Test camera".utf8) + [0]
        let firstValues = 8 + 2 + 3 * 12 + 4
        let rawDirectory = firstValues + model.count + (model.count % 2)
        put16(3)
        entry(254, 4, 1, 1)
        entry(330, 4, 1, rawDirectory)
        entry(50708, 2, model.count, firstValues)
        put32(0)
        out += model
        if out.count % 2 == 1 { out.append(0) }
        // The raw picture's directory, then its values, then the tiles to the end of the file.
        let entries = 15
        let values = rawDirectory + 2 + entries * 12 + 4
        let offsetsAt = values, countsAt = offsetsAt + tiles.count * 4, noiseAt = countsAt + tiles.count * 4
        var tileAt = noiseAt + 16
        put16(entries)
        entry(254, 4, 1, 0)
        entry(256, 4, 1, width)
        entry(257, 4, 1, height)
        entry(258, 3, 1, 16)
        entry(259, 3, 1, compressed ? 7 : 1)
        entry(262, 3, 1, 32803)
        entry(277, 3, 1, 1)
        entry(322, 4, 1, tile.0)
        entry(323, 4, 1, tile.1)
        entry(324, 4, tiles.count, offsetsAt)
        entry(325, 4, tiles.count, countsAt)
        put16(33421); put16(3); put32(2); put16(2); put16(2)
        entry(50714, 3, 1, 528)
        entry(50717, 3, 1, 4095)
        entry(51041, 12, 2, noiseAt)
        put32(0)
        for piece in tiles {
            put32(tileAt)
            tileAt += piece.count
        }
        for piece in tiles { put32(piece.count) }
        put64(2e-5)
        put64(3e-7)
        for piece in tiles { out += piece }
        return Data(out)
    }

    /// Where the raw picture's samples start: everything before is the rest of the file.
    static func rawStart(of file: Data) -> Int {
        let bytes = [UInt8](file)
        let big = bytes[0] == 0x4D
        func u32(_ at: Int) -> Int {
            let b = (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]), Int(bytes[at + 3]))
            return big ? b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3 : b.3 << 24 | b.2 << 16 | b.1 << 8 | b.0
        }
        // The first directory's second entry points at the raw picture's directory; its tenth entry at the tile offsets.
        let raw = u32(8 + 2 + 12 + 8)
        return u32(u32(raw + 2 + 9 * 12 + 8))
    }

    static func cameraModel(of file: Data) -> String {
        let bytes = [UInt8](file)
        let big = bytes[0] == 0x4D
        func u32(_ at: Int) -> Int {
            let b = (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]), Int(bytes[at + 3]))
            return big ? b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3 : b.3 << 24 | b.2 << 16 | b.1 << 8 | b.0
        }
        let at = u32(8 + 2 + 24 + 8)
        return String(decoding: bytes[at..<(at + 11)], as: UTF8.self)
    }
}
