import Foundation

/// The part of an edit that carries over to another photo: its look.
///
/// Crop, detail and local adjustments belong to the photo they were made on and are left out;
/// grain and halation are part of the look and carry over. White balance
/// is kept as a shift from the as-shot value, so "a little warmer" stays a little warmer on a photo
/// taken in different light.
public struct Look: Codable, Equatable, Sendable {
    public var global: [String: Double]
    public var temperatureShift: Double
    public var tintShift: Double
    public var curves: [String: [[Double]]]
    public var hsl: [String: [String: Double]]
    public var grading: Grading
    public var grain: [String: Double]
    public var halation: [String: Double]

    enum CodingKeys: String, CodingKey {
        case global, temperatureShift, tintShift, curves, hsl, grading, grain, halation
    }

    /// Looks saved before grain and halation existed have none.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        global = try container.decode([String: Double].self, forKey: .global)
        temperatureShift = try container.decode(Double.self, forKey: .temperatureShift)
        tintShift = try container.decode(Double.self, forKey: .tintShift)
        curves = try container.decode([String: [[Double]]].self, forKey: .curves)
        hsl = try container.decode([String: [String: Double]].self, forKey: .hsl)
        grading = try container.decode(Grading.self, forKey: .grading)
        grain = try container.decodeIfPresent([String: Double].self, forKey: .grain) ?? EditingState.defaults(Specs.grain)
        halation = try container.decodeIfPresent([String: Double].self, forKey: .halation) ?? EditingState.defaults(Specs.halation)
    }

    public init(state: EditingState, defaults: PhotoDefaults) {
        let base = EditingState(defaults: defaults)
        var global = state.global
        global["temperature"] = nil
        global["tint"] = nil
        self.global = global
        temperatureShift = state.value("temperature") - base.value("temperature")
        tintShift = state.value("tint") - base.value("tint")
        curves = state.curves
        hsl = state.hsl
        grading = state.grading
        grain = state.grain
        halation = state.halation
    }

    /// The photo's state with this look in place of its own. Its crop and detail settings stay.
    public func applied(to state: EditingState, defaults: PhotoDefaults) -> EditingState {
        let base = EditingState(defaults: defaults)
        var result = state
        for spec in Specs.global where spec.name != "temperature" && spec.name != "tint" {
            result.global[spec.name] = min(spec.max, max(spec.min, global[spec.name] ?? spec.defaultValue))
        }
        let temperature = Specs.global[6]
        let tint = Specs.global[7]
        result.global["temperature"] = min(temperature.max, max(temperature.min, base.value("temperature") + temperatureShift))
        result.global["tint"] = min(tint.max, max(tint.min, base.value("tint") + tintShift))
        result.curves = curves
        result.hsl = hsl
        result.grading = grading
        result.grain = grain
        result.halation = halation
        return result
    }
}

/// A style: a look with a name, to put on any photo.
public struct Style: Codable, Equatable, Sendable, Identifiable {
    /// What a style is made of.
    public enum Recipe: Equatable, Sendable {
        /// The whole look of a photo edited in Oscuru: it replaces the photo's tone, colour, grain and halation.
        case look(Look)
        /// Tone and colour fitted from an original and its edit. Exposure and white balance stay the photo's own.
        case fit(LookFit)
        /// The fingerprint of one picture, matched afresh on each photo. Exposure and white balance stay the photo's own.
        case match(StyleFingerprint)
    }

    public var id: String
    public var name: String
    public var createdAt: Date
    public var recipe: Recipe

    public init(id: String, name: String, createdAt: Date, recipe: Recipe) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.recipe = recipe
    }

    /// The photo's settings with this style in place. `render` gives the photo with the settings
    /// it is handed as a small bitmap; only a style matched from one picture asks for it.
    public func applied(to state: EditingState, defaults: PhotoDefaults, render: (EditingState) -> PixelBuffer?) throws -> EditingState {
        switch recipe {
        case .look(let look):
            return look.applied(to: state, defaults: defaults)
        case .fit(let fit):
            return try fit.applied(to: state)
        case .match(let fingerprint):
            guard let pixels = render(LookFit.base(state, wholeFrame: false)) else { throw StateError("the photo could not be rendered to match the style") }
            return try LookFitting.match(source: pixels, fingerprint: fingerprint).applied(to: state)
        }
    }

    // On disk a style is {id, name, createdAt} and one of look, fit or match. Files written by
    // earlier versions also carry a placeholder look beside a fit or match.
    private enum CodingKeys: String, CodingKey { case id, name, createdAt, look, fit, match }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let fingerprint = try container.decodeIfPresent(StyleFingerprint.self, forKey: .match) {
            recipe = .match(fingerprint)
        } else if let fit = try container.decodeIfPresent(LookFit.self, forKey: .fit) {
            recipe = .fit(fit)
        } else {
            recipe = .look(try container.decode(Look.self, forKey: .look))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        switch recipe {
        case .look(let look): try container.encode(look, forKey: .look)
        case .fit(let fit): try container.encode(fit, forKey: .fit)
        case .match(let fingerprint): try container.encode(fingerprint, forKey: .match)
        }
    }
}

/// The person's styles. Names are unique without regard to case; saving under an existing name
/// replaces that style.
public struct StyleCollection: Codable, Equatable, Sendable {
    public private(set) var styles: [Style] = []

    // The list keeps the name it was first saved under.
    private enum CodingKeys: String, CodingKey { case styles = "filters" }

    public init() {}

    public static func cleanName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }

    public func named(_ name: String) -> Style? {
        let wanted = StyleCollection.cleanName(name).lowercased()
        return styles.first { $0.name.lowercased() == wanted }
    }

    /// Saves a style under a name. Returns nil when the name is empty.
    @discardableResult
    public mutating func save(name: String, recipe: Style.Recipe, id: String, now: Date) -> Style? {
        let clean = StyleCollection.cleanName(name)
        guard !clean.isEmpty else { return nil }
        if let index = styles.firstIndex(where: { $0.name.lowercased() == clean.lowercased() }) {
            styles[index].name = clean
            styles[index].recipe = recipe
            return styles[index]
        }
        let style = Style(id: id, name: clean, createdAt: now, recipe: recipe)
        styles.append(style)
        return style
    }

    /// Renames a style. Returns false when the name is empty or belongs to another style.
    public mutating func rename(id: String, to name: String) -> Bool {
        let clean = StyleCollection.cleanName(name)
        guard !clean.isEmpty, let index = styles.firstIndex(where: { $0.id == id }) else { return false }
        if let other = named(clean), other.id != id { return false }
        styles[index].name = clean
        return true
    }

    public mutating func delete(id: String) {
        styles.removeAll { $0.id == id }
    }
}
