import Foundation
import XCTest

@testable import OscuruCore

final class JSONValueTests: XCTestCase {
    private func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    // MARK: Literals and accessors

    func testLiteralsBuildTheMatchingCases() {
        let value: JSONValue = ["text": "hi", "whole": 3, "fraction": 0.5, "flag": true, "nothing": nil, "list": [1, "two", false]]
        XCTAssertEqual(
            value,
            .object([
                "text": .string("hi"), "whole": .number(3), "fraction": .number(0.5), "flag": .bool(true), "nothing": .null,
                "list": .array([.number(1), .string("two"), .bool(false)]),
            ]))
    }

    func testADictionaryLiteralWithARepeatedKeyKeepsTheLastValue() {
        let value: JSONValue = ["a": 1, "a": 2]
        XCTAssertEqual(value, .object(["a": .number(2)]))
    }

    func testAccessorsReturnTheValueOnlyForTheirOwnKind() {
        let object: JSONValue = ["name": "aqua", "count": 2, "on": true, "items": [1, 2]]
        XCTAssertEqual(object["name"]?.stringValue, "aqua")
        XCTAssertEqual(object["count"]?.doubleValue, 2)
        XCTAssertEqual(object["on"]?.boolValue, true)
        XCTAssertEqual(object["items"]?.arrayValue, [.number(1), .number(2)])
        XCTAssertEqual(object.objectValue?.count, 4)

        XCTAssertNil(object["name"]?.doubleValue)
        XCTAssertNil(object["count"]?.stringValue)
        XCTAssertNil(object["count"]?.boolValue)
        XCTAssertNil(object["on"]?.doubleValue)
        XCTAssertNil(object["items"]?.objectValue)
        XCTAssertNil(object.arrayValue)
    }

    func testSubscriptIsNilForAMissingKeyAndForValuesThatAreNotObjects() {
        let object: JSONValue = ["present": nil]
        XCTAssertEqual(object["present"], .some(.null))
        XCTAssertNil(object["missing"])
        XCTAssertNil(JSONValue.array([1])["present"])
        XCTAssertNil(JSONValue.string("present")["present"])
        XCTAssertNil(JSONValue.null["present"])
    }

    // MARK: Codable

    func testDecodesEveryKindOfValue() throws {
        let value = try decode(#"{"a":null,"b":true,"c":1.5,"d":"x","e":[1,false,"two",[]],"f":{"g":0,"h":{}}}"#)
        XCTAssertEqual(value, ["a": nil, "b": true, "c": 1.5, "d": "x", "e": [1, false, "two", []], "f": ["g": 0, "h": [:]]])
    }

    func testNumbersAreNeverMistakenForBooleansOrStrings() throws {
        XCTAssertEqual(try decode(#"[0, 1, true, false, "1", "true", -2, 1e3]"#), [.number(0), .number(1), .bool(true), .bool(false), .string("1"), .string("true"), .number(-2), .number(1000)])
    }

    func testEncodingAndDecodingRoundTrips() throws {
        let value: JSONValue = [
            "null": nil, "bool": false, "number": -12.25, "string": "line\nbreak \"quoted\" é 😀", "array": [1, [2, [3]], [:]],
            "object": ["nested": ["deep": true]],
        ]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    func testDecodingRejectsTextThatIsNotJSON() {
        XCTAssertThrowsError(try decode("{not json"))
        XCTAssertThrowsError(try decode(""))
    }

    // MARK: Text

    func testTextIsCompactWithKeysInAlphabeticalOrder() {
        let value: JSONValue = ["b": 1, "a": [true, nil, "x"], "c": ["z": 1.5, "y": -2], "B": 0]
        XCTAssertEqual(value.text(), #"{"B":0,"a":[true,null,"x"],"b":1,"c":{"y":-2,"z":1.5}}"#)
    }

    func testTextOfScalarsAndEmptyContainers() {
        XCTAssertEqual(JSONValue.null.text(), "null")
        XCTAssertEqual(JSONValue.bool(true).text(), "true")
        XCTAssertEqual(JSONValue.bool(false).text(), "false")
        XCTAssertEqual(JSONValue.number(12).text(), "12")
        XCTAssertEqual(JSONValue.number(-0.35).text(), "-0.35")
        XCTAssertEqual(JSONValue.string("").text(), "\"\"")
        XCTAssertEqual(JSONValue.array([]).text(), "[]")
        XCTAssertEqual(JSONValue.object([:]).text(), "{}")
        XCTAssertEqual(JSONValue.array([]).text(pretty: true), "[]")
        XCTAssertEqual(JSONValue.object([:]).text(pretty: true), "{}")
    }

    func testTextEscapesQuotesBackslashesAndControlCharacters() {
        let value = JSONValue.string("a\"b\\c\nd\re\tf\u{01}g\u{1f}h é 😀 /")
        XCTAssertEqual(value.text(), #""a\"b\\c\nd\re\tf\u0001g\u001fh é 😀 /""#)
    }

    func testTextEscapesObjectKeysToo() {
        let value: JSONValue = ["a \"key\"\n": 1]
        XCTAssertEqual(value.text(), #"{"a \"key\"\n":1}"#)
        XCTAssertEqual(value.text(pretty: true), "{\n  \"a \\\"key\\\"\\n\": 1\n}")
    }

    func testTextWritesNumbersThatAreNotFiniteAsNull() {
        let value: JSONValue = [.number(.nan), .number(.infinity), .number(-.infinity), 1]
        XCTAssertEqual(value.text(), "[null,null,null,1]")
    }

    func testPrettyTextIndentsByTwoSpacesPerLevel() {
        let value: JSONValue = ["b": ["y": [], "x": [:]], "a": [1, ["k": "v"]], "c": "end"]
        let expected = """
            {
              "a": [
                1,
                {
                  "k": "v"
                }
              ],
              "b": {
                "x": {},
                "y": []
              },
              "c": "end"
            }
            """
        XCTAssertEqual(value.text(pretty: true), expected)
    }

    func testInitFromTextParsesObjectsArraysAndBareValues() {
        XCTAssertEqual(JSONValue(text: #"{"code":"photo.current.adjust({})","baseRevision":3}"#), ["code": "photo.current.adjust({})", "baseRevision": 3])
        XCTAssertEqual(JSONValue(text: " [1, 2,\n 3] "), [1, 2, 3])
        XCTAssertEqual(JSONValue(text: "12"), .number(12))
        XCTAssertEqual(JSONValue(text: "\"aqua\""), .string("aqua"))
        XCTAssertEqual(JSONValue(text: "true"), .bool(true))
        XCTAssertEqual(JSONValue(text: "null"), .some(.null))
    }

    func testInitFromTextIsNilForInvalidJSON() {
        XCTAssertNil(JSONValue(text: ""))
        XCTAssertNil(JSONValue(text: "{not json"))
        XCTAssertNil(JSONValue(text: "{\"a\":}"))
        XCTAssertNil(JSONValue(text: "[1, 2"))
        XCTAssertNil(JSONValue(text: "undefined"))
    }

    func testTextRoundTripsThroughInitFromText() {
        let value: JSONValue = [
            "state": ["global": ["exposureEV": 0.35, "temperature": 5235], "curves": ["rgb": [[0, 0.03], [1, 0.98]]]],
            "note": "tab\tquote\" backslash\\ newline\n control\u{02} è",
            "flags": [true, false, nil],
        ]
        XCTAssertEqual(JSONValue(text: value.text()), value)
        XCTAssertEqual(JSONValue(text: value.text(pretty: true)), value)
    }

    // MARK: Descriptions

    func testDescribedShowsAValueTheWayAScriptAuthorWroteIt() {
        XCTAssertEqual(JSONValue.null.described, "null")
        XCTAssertEqual(JSONValue.bool(true).described, "true")
        XCTAssertEqual(JSONValue.bool(false).described, "false")
        XCTAssertEqual(JSONValue.number(12).described, "12")
        XCTAssertEqual(JSONValue.number(-0.35).described, "-0.35")
        XCTAssertEqual(JSONValue.string("aqua").described, "\"aqua\"")
        XCTAssertEqual(JSONValue.string("say \"hi\"").described, #""say \"hi\"""#)
        XCTAssertEqual(JSONValue.array([1, 2]).described, "an array")
        XCTAssertEqual(JSONValue.object(["a": 1]).described, "an object")
    }

    func testDescribedNamesNumbersThatAreNotFiniteAsJavaScriptDoes() {
        XCTAssertEqual(JSONValue.number(.nan).described, "NaN")
        XCTAssertEqual(JSONValue.number(.infinity).described, "Infinity")
        XCTAssertEqual(JSONValue.number(-.infinity).described, "-Infinity")
    }

    // MARK: formatNumber

    func testFormatNumberPrintsWholeNumbersWithoutADecimalPoint() {
        XCTAssertEqual(formatNumber(0), "0")
        XCTAssertEqual(formatNumber(-0.0), "0")
        XCTAssertEqual(formatNumber(12), "12")
        XCTAssertEqual(formatNumber(-5), "-5")
        XCTAssertEqual(formatNumber(25000), "25000")
        XCTAssertEqual(formatNumber(1_000_000), "1000000")
        XCTAssertEqual(formatNumber(123_456_789_012), "123456789012")
        XCTAssertEqual(formatNumber(1e15), "1000000000000000")
    }

    func testFormatNumberPrintsDecimalsWithoutTrailingZeros() {
        XCTAssertEqual(formatNumber(0.35), "0.35")
        XCTAssertEqual(formatNumber(2.5), "2.5")
        XCTAssertEqual(formatNumber(0.05), "0.05")
        XCTAssertEqual(formatNumber(0.004), "0.004")
        XCTAssertEqual(formatNumber(1234.5678), "1234.5678")
        XCTAssertEqual(formatNumber(0.1 + 0.2), "0.3")
    }

    func testFormatNumberKeepsAtMostSixDecimals() {
        XCTAssertEqual(formatNumber(1.0 / 3), "0.333333")
        XCTAssertEqual(formatNumber(2.0 / 3), "0.666667")
        XCTAssertEqual(formatNumber(0.123456789), "0.123457")
    }

    func testFormatNumberPrintsNegativeDecimals() {
        XCTAssertEqual(formatNumber(-0.5), "-0.5")
        XCTAssertEqual(formatNumber(-45.25), "-45.25")
        XCTAssertEqual(formatNumber(-1.0 / 3), "-0.333333")
    }

    func testFormatNumberNamesValuesThatAreNotFiniteAsJavaScriptDoes() {
        XCTAssertEqual(formatNumber(.nan), "NaN")
        XCTAssertEqual(formatNumber(.infinity), "Infinity")
        XCTAssertEqual(formatNumber(-.infinity), "-Infinity")
    }
}
