import Foundation
import OscuruCore

/// What scripts need from the app while they run. Every method is called on the script's own
/// thread and may block while the engine renders.
public protocol ScriptHost: AnyObject {
    /// Measurements of the photo rendered with these settings.
    func analysis(of state: EditingState) -> ImageAnalysis?
    /// An sRGB JPEG of the photo rendered with these settings. `region` is part of the frame, as
    /// fractions from its top-left corner.
    func image(of state: EditingState, region: ScriptRegion?, maxEdge: Int) -> Data?
    /// An sRGB JPEG of the photo with the area `mask` covers painted red, and the share of the frame
    /// it covers (0 to 1).
    func maskImage(of state: EditingState, mask: Mask, region: ScriptRegion?, maxEdge: Int) -> (jpeg: Data, coverage: Double)?
    /// An sRGB JPEG of how far each part of the frame is, as greys from black (nearest) to white
    /// (farthest). Nil when this build cannot estimate depth.
    func depthImage(of state: EditingState, region: ScriptRegion?, maxEdge: Int) -> Data?
    /// The open photo with these settings as a small Display P3 bitmap: what a style learned from
    /// one picture is matched on.
    func pixels(of state: EditingState) -> PixelBuffer?
    /// Merges a shot's frames the way these settings say (making the merge now if it is not kept
    /// already), and returns what lining each frame up found, by frame number. Nil when the photo's
    /// frames cannot be merged that way (they are gone, or cannot be read).
    func frameReports(of state: EditingState) -> [Int: FrameReport]?
    func styleNames() -> [String]
    func style(named name: String) -> Style?
    /// Saves the look of the photo with these settings as a style, replacing one of the same name.
    /// False when the name is unusable.
    func saveStyle(name: String, state: EditingState) -> Bool
    func deleteStyle(name: String) -> Bool
}

public struct ScriptRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ScriptRequest: Sendable {
    public var code: String
    /// The photo's settings when the script starts.
    public var state: EditingState
    public var info: PhotoInfo
    /// The photo's settings when the person gave the instruction this script belongs to.
    public var before: EditingState

    public init(code: String, state: EditingState, info: PhotoInfo, before: EditingState) {
        self.code = code
        self.state = state
        self.info = info
        self.before = before
    }
}

public struct ScriptFailure: Equatable, Sendable {
    /// The JavaScript error's name: SyntaxError, RangeError, TypeError, Error, or Cancelled.
    public var name: String
    public var message: String
    /// 1-based line in the script, when known.
    public var line: Int?
    public var column: Int?

    public var json: JSONValue {
        var members: [String: JSONValue] = ["name": .string(name), "message": .string(message)]
        if let line { members["line"] = .number(Double(line)) }
        if let column { members["column"] = .number(Double(column)) }
        return .object(members)
    }
}

public struct ScriptOutcome: Sendable {
    /// Nil when the script ran to its end.
    public var error: ScriptFailure?
    /// The settings to make current: the script's result, or the starting settings when it failed.
    public var state: EditingState
    public var changes: [EditingState.Change]
    public var logs: [String]
    /// The value of the script's last expression, as text.
    public var returnValue: String?
    /// Pictures the script asked for with `photo.show`.
    public var shown: [LabeledImage]
    public var durationMs: Int
    /// The settings of each new photo the script asked to split off (`photo.split`); only when it
    /// ran to its end without an error.
    public var parts: [EditingState] = []
}
