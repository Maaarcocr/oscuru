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
        return .object(members)
    }
}
