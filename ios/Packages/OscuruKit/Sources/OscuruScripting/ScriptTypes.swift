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
    func filterNames() -> [String]
    func look(named name: String) -> Look?
    /// Saves a look under a name, replacing a filter of the same name. False when the name is unusable.
    func saveFilter(name: String, look: Look) -> Bool
    func deleteFilter(name: String) -> Bool
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
    public var revision: Int
    public var info: PhotoInfo
    /// The photo's settings when the person gave the instruction this script belongs to.
    public var before: EditingState

    public init(code: String, state: EditingState, revision: Int, info: PhotoInfo, before: EditingState) {
        self.code = code
        self.state = state
        self.revision = revision
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
}
