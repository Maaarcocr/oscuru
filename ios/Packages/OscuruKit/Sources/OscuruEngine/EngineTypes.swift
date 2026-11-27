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
    /// There is not room in memory for `what` now (it needs about `needed` bytes, `available` are left).
    case notEnoughMemory(String, needed: Int, available: Int)

    public var description: String {
        switch self {
        case .cannotOpen(let detail): return "Cannot open this photo: \(detail)"
        case .unknownPhoto(let id): return "No open photo with id \(id)"
        case .renderFailed(let detail): return "Rendering failed: \(detail)"
        case .notEnoughMemory(let what, let needed, let available):
            return "There is not enough memory to \(what) now: it needs about \(needed / 1_000_000) MB and \(available / 1_000_000) MB is left. "
                + "Use fewer frames or merge at scale 1, or try again once other photos are done."
        }
    }
}
