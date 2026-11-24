import Foundation
import OscuruCore

public struct RenderOptions {
    /// Long edge of the output in pixels. 0 renders at full resolution.
    public var maxEdge: Double = 0
    /// Ignore the crop rectangle and vignette.
    public var fullFrame = false
    /// Render only this part of the (cropped) frame, as fractions from its top-left corner.
    public var region: CGRect?
    /// Paint the area this mask covers red over the photo.
    public var mask: Mask?
    /// Show how far each part of the frame is instead of the photo, as greys: black nearest, white farthest.
    public var depth = false

    public init(maxEdge: Double = 0, fullFrame: Bool = false, region: CGRect? = nil, mask: Mask? = nil, depth: Bool = false) {
        self.maxEdge = maxEdge
        self.fullFrame = fullFrame
        self.region = region
        self.mask = mask
        self.depth = depth
    }
}

public enum EngineError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case unknownPhoto(String)
    case renderFailed(String)

    public var description: String {
        switch self {
        case .cannotOpen(let detail): return "Cannot open this photo: \(detail)"
        case .unknownPhoto(let id): return "No open photo with id \(id)"
        case .renderFailed(let detail): return "Rendering failed: \(detail)"
        }
    }
}
