import Foundation
import XCTest

@testable import OscuruCore

/// Learning a look from a pair (exact) and from a reference of another scene (approximate).
final class LookFittingTests: XCTestCase {
    /// A test scene: a ramp from black to white left to right, with colour varying top to bottom.
    private func scene(width: Int = 240, height: Int = 180, _ transform: ((Double, Double, Double)) -> (Double, Double, Double) = { $0 }) -> PixelBuffer {
        var data = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Double(x) / Double(width - 1)
                let t = Double(y) / Double(height - 1)
                let source = (min(1, v * (0.7 + 0.3 * t)), v, min(1, v * (1 - 0.35 * t)))
                let out = transform(source)
                let offset = (y * width + x) * 4
                data[offset] = UInt8((min(1, max(0, out.0)) * 255).rounded())
                data[offset + 1] = UInt8((min(1, max(0, out.1)) * 255).rounded())
                data[offset + 2] = UInt8((min(1, max(0, out.2)) * 255).rounded())
                data[offset + 3] = 255
            }
        }
        return PixelBuffer(rgba: data, width: width, height: height)
    }

    private func look() throws -> EditingState {
        var state = EditingState()
        try state.setCurve(channel: "red", points: [[0, 0.02], [0.5, 0.3], [1, 0.95]])
        try state.setCurve(channel: "green", points: [[0, 0.05], [0.5, 0.28], [1, 0.9]])
        try state.setCurve(channel: "blue", points: [[0, 0.06], [0.5, 0.25], [1, 0.82]])
        try state.adjust(["saturation": 16])
        return state
    }

    func testAPairFitFindsTheLookThatMadeTheEdit() throws {
        let state = try look()
        let original = scene()
        let edited = scene { ColorPipeline.apply(state, to: $0) }
        let fit = try LookFitting.fit(original: original, edited: edited)
        XCTAssertLessThan(fit.error ?? 99, 3, "the fitted look reproduces the edit to within a few levels")
        XCTAssertEqual(Set(fit.curves.keys), ["red", "green", "blue"])
        // The channel curves take up part of a saturation change, so the number need not match; the result does.
        XCTAssertGreaterThanOrEqual(fit.saturation, 0)
        // The curves pass the editor's own checks and can be set as they are.
        let applied = try fit.applied(to: EditingState())
        XCTAssertTrue(applied.isIdentityCurve("rgb"))
        XCTAssertEqual(try EditingState(json: applied.json), applied)
        // White went to the edit's warm cream.
        let white = ColorPipeline.apply(applied, to: (1, 1, 1))
        XCTAssertGreaterThan(white.0, white.2)
    }

    func testAPairOfAPictureWithItselfIsNoChange() throws {
        let original = scene()
        let fit = try LookFitting.fit(original: original, edited: original)
        XCTAssertLessThan(fit.error ?? 99, 1)
        XCTAssertEqual(fit.saturation, 0, accuracy: 4)
        for points in fit.curves.values {
            for point in points { XCTAssertEqual(point[1], point[0], accuracy: 0.02) }
        }
    }

    func testAPairMustBeTheSameFraming() {
        XCTAssertThrowsError(try LookFitting.fit(original: scene(width: 240, height: 180), edited: scene(width: 180, height: 240))) { error in
            XCTAssertTrue(String(describing: error).contains("not the same framing"))
        }
        // A different size with the same proportions is fine.
        XCTAssertNoThrow(try LookFitting.fit(original: scene(width: 240, height: 180), edited: scene(width: 120, height: 90)))
    }

    func testAMatchMovesTheToneAndColourTowardsTheReference() throws {
        let source = scene()
        let reference = scene { (0.1 + $0.0 * 0.75, 0.08 + $0.1 * 0.7, 0.05 + $0.2 * 0.6) }
        let full = try LookFitting.match(source: source, reference: reference)
        let applied = try full.applied(to: EditingState())
        // Black lifts and white comes down and warms, like the reference.
        let black = ColorPipeline.apply(applied, to: (0, 0, 0))
        let white = ColorPipeline.apply(applied, to: (1, 1, 1))
        XCTAssertGreaterThan(black.0, 0.05)
        XCTAssertLessThan(white.2, 0.75)
        XCTAssertGreaterThan(white.0, white.2)
        XCTAssertNil(full.error)

        let none = try LookFitting.match(source: source, reference: reference, strength: 0)
        for points in none.curves.values {
            for point in points { XCTAssertEqual(point[1], point[0], accuracy: 1e-9) }
        }
        XCTAssertEqual(none.saturation, 0)
    }

    func testCurvesStayValidWhateverThePictures() throws {
        // A picture that is mostly one value (a white sky) still gives curves the editor accepts.
        let sky = scene { _ in (1, 1, 1) }
        let fit = try LookFitting.fit(original: sky, edited: scene())
        XCTAssertNoThrow(try fit.applied(to: EditingState()))
        let matched = try LookFitting.match(source: sky, reference: scene())
        XCTAssertNoThrow(try matched.applied(to: EditingState()))
    }

    func testApplyingALookReplacesToneAndColourOnly() throws {
        var state = EditingState(defaults: PhotoDefaults(temperature: 5200))
        try state.adjust(["exposureEV": 0.7, "contrast": 30, "vibrance": 20, "highlights": -40])
        try state.setCurve(channel: "rgb", points: [[0, 0.1], [1, 0.9]])
        try state.adjustHSL(color: "red", adjustments: ["saturation": 20])
        try state.setGrain(["amount": 20])
        let look = try LookFitting.fit(original: scene(), edited: scene { ($0.0 * 0.8, $0.1 * 0.8, $0.2 * 0.7) })
        let applied = try LookFit(json: look.json).applied(to: state)
        XCTAssertEqual(applied.value("exposureEV"), 0.7, "the photo's own exposure stays")
        XCTAssertEqual(applied.value("temperature"), 5200)
        XCTAssertEqual(applied.value("highlights"), -40)
        XCTAssertEqual(applied.grain["amount"], 20)
        XCTAssertEqual(applied.value("contrast"), 0, "the look replaces tone and colour")
        XCTAssertEqual(applied.value("vibrance"), 0)
        XCTAssertTrue(applied.isIdentityCurve("rgb"))
        XCTAssertEqual(applied.hsl["red"]?["saturation"], 0)
        XCTAssertEqual(applied.value("saturation"), look.saturation)

        XCTAssertThrowsError(try LookFit(json: ["curves": ["alpha": [[0, 0], [1, 1]]], "saturation": 0]))
        XCTAssertThrowsError(try LookFit(json: ["curves": ["red": [[0, 0]]], "saturation": 0]))
        XCTAssertThrowsError(try LookFit(json: "warm"))
    }

    // MARK: Styles

    func testStylesFromPicturesApplyAndOldStylesStillLoad() throws {
        var state = EditingState(defaults: PhotoDefaults(temperature: 5200))
        try state.adjust(["exposureEV": 0.5, "contrast": 20])
        let classicLook = Look(state: try edited(), defaults: PhotoDefaults())
        let fit = try LookFitting.fit(original: scene(), edited: scene { ($0.0 * 0.8, $0.1 * 0.8, $0.2 * 0.7) })
        let fingerprint = LookFitting.fingerprint(of: scene { (0.1 + $0.0 * 0.8, 0.08 + $0.1 * 0.75, 0.05 + $0.2 * 0.65) })

        // A style from a pair: its curves, the photo's own exposure and white balance.
        let pair = Style(id: "p", name: "Pair", createdAt: Date(), recipe: .fit(fit))
        let fromPair = try pair.applied(to: state, defaults: PhotoDefaults(temperature: 5200)) { _ in XCTFail("a fitted style needs no measuring"); return nil }
        XCTAssertEqual(fromPair.value("exposureEV"), 0.5)
        XCTAssertEqual(fromPair.value("contrast"), 0)
        XCTAssertEqual(fromPair.curves["blue"], fit.curves["blue"])

        // A style from one picture is matched on the photo it goes on, measured without its own tone and colour.
        var measured: [EditingState] = []
        let single = Style(id: "s", name: "Single", createdAt: Date(), recipe: .match(fingerprint))
        let fromSingle = try single.applied(to: state, defaults: PhotoDefaults()) {
            measured.append($0)
            return scene()
        }
        XCTAssertEqual(measured, [LookFit.base(state, wholeFrame: false)])
        XCTAssertFalse(fromSingle.isIdentityCurve("blue"))
        XCTAssertEqual(fromSingle.value("exposureEV"), 0.5)
        XCTAssertThrowsError(try single.applied(to: state, defaults: PhotoDefaults()) { _ in nil }, "a photo that cannot be rendered cannot be matched")

        // A style from an edit in Oscuru is the whole look.
        let classic = Style(id: "c", name: "Classic", createdAt: Date(), recipe: .look(classicLook))
        XCTAssertEqual(try classic.applied(to: state, defaults: PhotoDefaults()) { _ in nil }, classicLook.applied(to: state, defaults: PhotoDefaults()))

        // Each kind saves and loads as itself.
        for style in [pair, single, classic] {
            XCTAssertEqual(try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style)), style)
        }
        // Earlier versions saved a placeholder look beside a fit or a match: the fit or match is what counts.
        var json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(single))
        guard var members = json.objectValue else { return XCTFail("not an object") }
        members["look"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(classicLook))
        json = .object(members)
        XCTAssertEqual(try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(json)), single)
        // And the list is read from the file it always was.
        var collection = StyleCollection()
        collection.save(name: "Classic", recipe: .look(classicLook), id: "c", now: Date(timeIntervalSince1970: 0))
        let saved = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(collection))
        XCTAssertEqual(saved["filters"]?.arrayValue?.count, 1)
    }

    private func edited() throws -> EditingState {
        var state = EditingState()
        try state.adjust(["exposureEV": -0.3, "saturation": 10])
        return state
    }
}
