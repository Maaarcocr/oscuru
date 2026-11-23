import Foundation
import OscuruCore

public struct RenderOptions {
    /// Long edge of the output in pixels. 0 renders at full resolution.
    public var maxEdge: Double = 0
    /// Ignore the crop rectangle and vignette.
    public var fullFrame = false
    /// Render only this part of the (cropped) frame, as fractions from its top-left corner.
    public var region: CGRect?

    public init(maxEdge: Double = 0, fullFrame: Bool = false, region: CGRect? = nil) {
        self.maxEdge = maxEdge
        self.fullFrame = fullFrame
        self.region = region
    }
}

public enum ExportFormat: String, Sendable {
    case jpeg
    case heic
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
