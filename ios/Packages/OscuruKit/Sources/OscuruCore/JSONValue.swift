import Foundation

/// Any JSON value. Used wherever data crosses a boundary whose shape we do not control:
/// what a script passes in, what the model sends, and what we send back to it.
public enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The member of an object, or nil when this is not an object or has no such key.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// The JSON text, with object keys in alphabetical order so that output is stable.
    public func text(pretty: Bool = false) -> String {
        var output = ""
        write(to: &output, indent: pretty ? 0 : nil)
        return output
    }

    public init?(text: String) {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        self = value
    }

    /// How a value appears in a message meant for whoever wrote a script: `"aqua"`, `12`, `an array`.
    public var described: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return formatNumber(value)
        case .string(let value): return JSONValue.string(value).text()
        case .array: return "an array"
        case .object: return "an object"
        }
    }

    private func write(to output: inout String, indent: Int?) {
        let newline = indent == nil ? "" : "\n"
        let pad = indent.map { String(repeating: "  ", count: $0 + 1) } ?? ""
        let closePad = indent.map { String(repeating: "  ", count: $0) } ?? ""
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let value): output += value.isFinite ? formatNumber(value) : "null"
        case .string(let value):
            output += "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": output += "\\\""
                case "\\": output += "\\\\"
                case "\n": output += "\\n"
                case "\r": output += "\\r"
                case "\t": output += "\\t"
                default:
                    if scalar.value < 0x20 {
                        output += String(format: "\\u%04x", scalar.value)
                    } else {
                        output.unicodeScalars.append(scalar)
                    }
                }
            }
            output += "\""
        case .array(let values):
            if values.isEmpty {
                output += "[]"
                return
            }
            output += "[" + newline
            for (index, value) in values.enumerated() {
                output += pad
                value.write(to: &output, indent: indent.map { $0 + 1 })
                output += (index < values.count - 1 ? "," : "") + newline
            }
            output += closePad + "]"
        case .object(let members):
            if members.isEmpty {
                output += "{}"
                return
            }
            output += "{" + newline
            let keys = members.keys.sorted()
            for (index, key) in keys.enumerated() {
                output += pad
                JSONValue.string(key).write(to: &output, indent: nil)
                output += indent == nil ? ":" : ": "
                members[key]!.write(to: &output, indent: indent.map { $0 + 1 })
                output += (index < keys.count - 1 ? "," : "") + newline
            }
            output += closePad + "}"
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// A number the way JavaScript would print it: no trailing ".0", up to 6 decimals.
public func formatNumber(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
    if value == value.rounded(), abs(value) < 1e15 {
        return String(Int64(value))
    }
    var text = String(format: "%.6f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}
