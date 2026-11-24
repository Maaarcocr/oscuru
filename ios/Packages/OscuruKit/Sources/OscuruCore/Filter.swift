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

    /// Filters saved before grain and halation existed have none.
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

public struct SavedFilter: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var look: Look

    public init(id: String, name: String, createdAt: Date, look: Look) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.look = look
    }
}

/// The person's saved filters. Names are unique without regard to case; saving under an existing
/// name replaces that filter.
public struct FilterCollection: Codable, Equatable, Sendable {
    public private(set) var filters: [SavedFilter] = []

    public init() {}

    public static func cleanName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }

    public func named(_ name: String) -> SavedFilter? {
        let wanted = FilterCollection.cleanName(name).lowercased()
        return filters.first { $0.name.lowercased() == wanted }
    }

    /// Saves a look under a name. Returns nil when the name is empty.
    @discardableResult
    public mutating func save(name: String, look: Look, id: String, now: Date) -> SavedFilter? {
        let clean = FilterCollection.cleanName(name)
        guard !clean.isEmpty else { return nil }
        if let index = filters.firstIndex(where: { $0.name.lowercased() == clean.lowercased() }) {
            filters[index].name = clean
            filters[index].look = look
            return filters[index]
        }
        let filter = SavedFilter(id: id, name: clean, createdAt: now, look: look)
        filters.append(filter)
        return filter
    }

    /// Renames a filter. Returns false when the name is empty or belongs to another filter.
    public mutating func rename(id: String, to name: String) -> Bool {
        let clean = FilterCollection.cleanName(name)
        guard !clean.isEmpty, let index = filters.firstIndex(where: { $0.id == id }) else { return false }
        if let other = named(clean), other.id != id { return false }
        filters[index].name = clean
        return true
    }

    public mutating func delete(id: String) {
        filters.removeAll { $0.id == id }
    }
}
