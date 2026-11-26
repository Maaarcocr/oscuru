import Foundation

/// What is known about an opened photo. Scripts read this through `getMetadata()`.
public struct PhotoInfo: Codable, Equatable, Sendable {
    public var fileName: String
    /// Uniform type identifier of the file, e.g. "com.adobe.raw-image".
    public var typeIdentifier: String
    public var isRaw: Bool
    /// Full-resolution size, upright, before any crop.
    public var width: Int
    public var height: Int
    /// Where this photo's settings start: as-shot white balance and the RAW decoder's own detail settings.
    public var defaults: PhotoDefaults
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Double?
    /// Shutter time in seconds.
    public var exposureTime: Double?
    public var aperture: Double?
    public var focalLength: Double?
    public var focalLength35mm: Double?
    public var dateTaken: String?
    /// A collage's pieces, in order: what its layout's cells refer to. Nil for a photo.
    public var pieces: [CollageManifest.Piece]?
    /// How many RAW frames the camera averaged into this file, when more than one: its noise is
    /// lower than its ISO says, by the square root of this. Kept in the photo's record.
    public var frames: Int?
    /// The frames themselves, when the camera kept them beside the file: what `photo.current.frames`
    /// works on. Read from the photo's folder each time it is opened.
    public var frameSet: FrameSet?

    public init(fileName: String, typeIdentifier: String, isRaw: Bool, width: Int, height: Int, defaults: PhotoDefaults = PhotoDefaults()) {
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
        self.isRaw = isRaw
        self.width = width
        self.height = height
        self.defaults = defaults
    }

    /// The metadata as scripts and the model see it.
    public var json: JSONValue {
        var members: [String: JSONValue] = [
            "fileName": .string(fileName),
            "typeIdentifier": .string(typeIdentifier),
            "isRaw": .bool(isRaw),
            "width": .number(Double(width)),
            "height": .number(Double(height)),
            "asShot": ["temperature": .number(defaults.temperature.rounded()), "tint": .number(defaults.tint.rounded())],
        ]
        if let make { members["make"] = .string(make) }
        if let model { members["model"] = .string(model) }
        if let lens { members["lens"] = .string(lens) }
        if let iso { members["iso"] = .number(iso) }
        if let exposureTime { members["exposureTime"] = .number(exposureTime) }
        if let aperture { members["aperture"] = .number(aperture) }
        if let focalLength { members["focalLength"] = .number(focalLength) }
        if let focalLength35mm { members["focalLength35mm"] = .number(focalLength35mm) }
        if let dateTaken { members["dateTaken"] = .string(dateTaken) }
        if let framing = defaults.framing {
            members["framedInCamera"] = ["x": .number(framing.x), "y": .number(framing.y), "width": .number(framing.width), "height": .number(framing.height)]
        }
        if let count = frameSet?.frames.count ?? frames, count > 1 { members["frames"] = .number(Double(count)) }
        if let frameSet { members["framesKept"] = .bool(frameSet.kept) }
        if let pieces {
            members["pieces"] = .array(
                pieces.enumerated().map { ["piece": .number(Double($0.offset)), "name": .string($0.element.name), "width": .number(Double($0.element.width)), "height": .number(Double($0.element.height))] })
        }
        return .object(members)
    }
}
