import Foundation
import XCTest

@testable import OscuruCore

final class FilterTests: XCTestCase {
    private let sourceDefaults = PhotoDefaults(temperature: 5200, tint: 8, sharpening: 40, noiseReduction: 50, colorNoiseReduction: 50)
    private let targetDefaults = PhotoDefaults(temperature: 3400, tint: -12, sharpening: 20, noiseReduction: 10, colorNoiseReduction: 30)

    /// An edit made on the source photo: warmer, with tone, curve, colour and grading changes, a crop and detail settings.
    private func sourceEdit() throws -> EditingState {
        try edited(EditingState(defaults: sourceDefaults)) { state in
            try state.adjust(["temperature": 5700, "tint": 3, "exposureEV": 0.4, "contrast": 15, "vibrance": -5, "vignette": -20])
            try state.setCurve(channel: "rgb", points: [[0, 0.03], [0.5, 0.52], [1, 0.98]])
            try state.adjustHSL(color: "blue", adjustments: ["saturation": -8, "luminance": -5])
            try state.setGrading(range: "shadows", settings: ["hue": 220, "saturation": 0.1])
            try state.configureGrading(["balance": 0.2])
            try state.setDetail(["sharpening": 70, "noiseReduction": 0])
            try state.setCrop(["x": 0.1, "width": 0.8, "angle": 2, "rotation": 90])
        }
    }

    private func makeLook() throws -> Look {
        Look(state: try sourceEdit(), defaults: sourceDefaults)
    }

    // MARK: Look

    func testALookCarriesWhiteBalanceAsAShiftFromAsShot() throws {
        let look = try makeLook()
        XCTAssertEqual(look.temperatureShift, 500)
        XCTAssertEqual(look.tintShift, -5)
        XCTAssertNil(look.global["temperature"], "the absolute white balance is not part of a look")
        XCTAssertNil(look.global["tint"])
        XCTAssertEqual(look.global.count, Specs.global.count - 2)
        XCTAssertEqual(look.global["exposureEV"], 0.4)
        XCTAssertEqual(look.global["contrast"], 15)
        XCTAssertEqual(look.curves, try sourceEdit().curves)
        XCTAssertEqual(look.hsl, try sourceEdit().hsl)
        XCTAssertEqual(look.grading, try sourceEdit().grading)
    }

    func testALookOfAnUntouchedPhotoHasNoShift() {
        let look = Look(state: EditingState(defaults: sourceDefaults), defaults: sourceDefaults)
        XCTAssertEqual(look.temperatureShift, 0)
        XCTAssertEqual(look.tintShift, 0)
    }

    func testApplyingALookLeavesTheTargetsCropAndDetailAlone() throws {
        let target = try edited(EditingState(defaults: targetDefaults)) { state in
            try state.setCrop(["y": 0.2, "height": 0.6, "flipHorizontal": true])
            try state.setDetail(["sharpening": 35])
        }
        let result = try makeLook().applied(to: target, defaults: targetDefaults)
        XCTAssertEqual(result.crop, target.crop)
        XCTAssertEqual(result.detail, target.detail)
        XCTAssertEqual(result.detail, ["sharpening": 35, "noiseReduction": 10, "colorNoiseReduction": 30])
        XCTAssertNotEqual(result.crop, try sourceEdit().crop)
    }

    func testApplyingALookReplacesToneAndColourSettings() throws {
        let source = try sourceEdit()
        // The target has edits of its own, which the look replaces rather than merges with.
        let target = try edited(EditingState(defaults: targetDefaults)) { state in
            try state.adjust(["exposureEV": -1, "saturation": 30, "clarity": 20])
            try state.setCurve(channel: "red", points: [[0, 0.1], [1, 1]])
            try state.adjustHSL(color: "green", adjustments: ["hue": 20])
            try state.setGrading(range: "highlights", settings: ["hue": 40, "saturation": 0.3])
        }
        let result = try makeLook().applied(to: target, defaults: targetDefaults)
        for spec in Specs.global where spec.name != "temperature" && spec.name != "tint" {
            XCTAssertEqual(result.global[spec.name], source.global[spec.name], spec.name)
        }
        XCTAssertEqual(result.value("saturation"), 0)
        XCTAssertEqual(result.value("clarity"), 0)
        XCTAssertEqual(result.curves, source.curves)
        XCTAssertEqual(result.hsl, source.hsl)
        XCTAssertEqual(result.grading, source.grading)
    }

    func testApplyingALookShiftsTheTargetsOwnWhiteBalance() throws {
        let result = try makeLook().applied(to: EditingState(defaults: targetDefaults), defaults: targetDefaults)
        XCTAssertEqual(result.value("temperature"), 3900, "500 K warmer than this photo's as-shot 3400 K")
        XCTAssertEqual(result.value("tint"), -17)
    }

    func testTheShiftIsMeasuredFromAsShotNotFromTheTargetsCurrentWhiteBalance() throws {
        let target = try edited(EditingState(defaults: targetDefaults)) { try $0.adjust(["temperature": 9000, "tint": 50]) }
        let result = try makeLook().applied(to: target, defaults: targetDefaults)
        XCTAssertEqual(result.value("temperature"), 3900)
        XCTAssertEqual(result.value("tint"), -17)
    }

    func testApplyingALookToItsOwnPhotoGivesTheSameLookBack() throws {
        let source = try sourceEdit()
        let result = try makeLook().applied(to: EditingState(defaults: sourceDefaults), defaults: sourceDefaults)
        XCTAssertEqual(result.global, source.global)
        XCTAssertEqual(Look(state: result, defaults: sourceDefaults), try makeLook())
    }

    func testTheShiftedWhiteBalanceIsClampedToItsRange() throws {
        let warm = try edited(EditingState(defaults: PhotoDefaults(temperature: 3000, tint: -100))) { try $0.adjust(["temperature": 24000, "tint": 150]) }
        let warmLook = Look(state: warm, defaults: PhotoDefaults(temperature: 3000, tint: -100))
        XCTAssertEqual(warmLook.temperatureShift, 21000)
        XCTAssertEqual(warmLook.tintShift, 250)
        let hot = PhotoDefaults(temperature: 10000, tint: 20)
        let warmed = warmLook.applied(to: EditingState(defaults: hot), defaults: hot)
        XCTAssertEqual(warmed.value("temperature"), 25000)
        XCTAssertEqual(warmed.value("tint"), 150)

        let cool = try edited(EditingState(defaults: PhotoDefaults(temperature: 20000, tint: 100))) { try $0.adjust(["temperature": 2500, "tint": -150]) }
        let coolLook = Look(state: cool, defaults: PhotoDefaults(temperature: 20000, tint: 100))
        let cold = PhotoDefaults(temperature: 4000, tint: -20)
        let cooled = coolLook.applied(to: EditingState(defaults: cold), defaults: cold)
        XCTAssertEqual(cooled.value("temperature"), 2000)
        XCTAssertEqual(cooled.value("tint"), -150)
    }

    func testALookWithMissingOrOutOfRangeSettingsStillGivesAValidState() throws {
        var look = try makeLook()
        look.global["contrast"] = 500
        look.global["exposureEV"] = -40
        look.global["vignette"] = nil
        let result = look.applied(to: try global(["vignette": -60]), defaults: PhotoDefaults())
        XCTAssertEqual(result.value("contrast"), 100)
        XCTAssertEqual(result.value("exposureEV"), -5)
        XCTAssertEqual(result.value("vignette"), 0, "a setting the look does not have goes to its default")
        XCTAssertEqual(Set(result.global.keys), Set(Specs.global.map(\.name)))
        // What comes out passes the editor's own validation.
        XCTAssertEqual(try EditingState(json: result.json), result)
    }

    func testALookRoundTripsThroughCodable() throws {
        let look = try makeLook()
        let data = try JSONEncoder().encode(look)
        XCTAssertEqual(try JSONDecoder().decode(Look.self, from: data), look)

        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(Set(json.objectValue?.keys.map { $0 } ?? []), ["global", "temperatureShift", "tintShift", "curves", "hsl", "grading", "grain", "halation"])
        XCTAssertEqual(json["temperatureShift"], 500)
        XCTAssertNil(json["crop"])
        XCTAssertNil(json["detail"])
    }

    // MARK: Collection

    func testSaveAddsAFilterAndReturnsIt() throws {
        var collection = FilterCollection()
        XCTAssertEqual(collection.filters, [])
        let saved = collection.save(name: "Warm film", look: try makeLook(), id: "f1", now: referenceDate)
        XCTAssertEqual(saved, SavedFilter(id: "f1", name: "Warm film", createdAt: referenceDate, look: try makeLook()))
        XCTAssertEqual(collection.filters, [try XCTUnwrap(saved)])

        collection.save(name: "Cool night", look: try makeLook(), id: "f2", now: referenceDate.addingTimeInterval(60))
        XCTAssertEqual(collection.filters.map(\.name), ["Warm film", "Cool night"])
        XCTAssertEqual(collection.filters.map(\.id), ["f1", "f2"])
    }

    func testSaveUnderAnExistingNameReplacesTheLookWhateverTheCase() throws {
        var collection = FilterCollection()
        let first = try makeLook()
        var second = first
        second.global["contrast"] = 40
        collection.save(name: "Warm film", look: first, id: "f1", now: referenceDate)
        let replaced = collection.save(name: "WARM FILM", look: second, id: "f2", now: referenceDate.addingTimeInterval(3600))

        XCTAssertEqual(collection.filters.count, 1)
        XCTAssertEqual(replaced?.id, "f1", "the filter keeps its identity")
        XCTAssertEqual(replaced?.createdAt, referenceDate, "and the day it was made")
        XCTAssertEqual(replaced?.name, "WARM FILM", "the name takes the new spelling")
        XCTAssertEqual(replaced?.look, second)
        XCTAssertEqual(collection.filters.first, replaced)
    }

    func testSaveCleansTheName() throws {
        var collection = FilterCollection()
        XCTAssertEqual(collection.save(name: "  Warm film \n", look: try makeLook(), id: "f1", now: referenceDate)?.name, "Warm film")
        let long = String(repeating: "a", count: 75)
        XCTAssertEqual(collection.save(name: long, look: try makeLook(), id: "f2", now: referenceDate)?.name, String(repeating: "a", count: 60))
        // The padded spelling of an existing name is the same filter.
        collection.save(name: "\twarm FILM  ", look: try makeLook(), id: "f3", now: referenceDate)
        XCTAssertEqual(collection.filters.map(\.id), ["f1", "f2"])
        XCTAssertEqual(collection.filters.first?.name, "warm FILM")
    }

    func testSaveRefusesAnEmptyName() throws {
        var collection = FilterCollection()
        XCTAssertNil(collection.save(name: "", look: try makeLook(), id: "f1", now: referenceDate))
        XCTAssertNil(collection.save(name: "  \n\t ", look: try makeLook(), id: "f2", now: referenceDate))
        XCTAssertEqual(collection.filters, [])
    }

    func testCleanNameTrimsAndLimitsLength() {
        XCTAssertEqual(FilterCollection.cleanName("  Portra  "), "Portra")
        XCTAssertEqual(FilterCollection.cleanName("Two  words"), "Two  words")
        XCTAssertEqual(FilterCollection.cleanName(" \n "), "")
        XCTAssertEqual(FilterCollection.cleanName(String(repeating: "é", count: 61)).count, 60)
        XCTAssertEqual(FilterCollection.cleanName(String(repeating: "x", count: 60)).count, 60)
    }

    func testNamedFindsAFilterWithoutRegardToCaseOrPadding() throws {
        var collection = FilterCollection()
        collection.save(name: "Warm film", look: try makeLook(), id: "f1", now: referenceDate)
        XCTAssertEqual(collection.named("Warm film")?.id, "f1")
        XCTAssertEqual(collection.named("warm FILM")?.id, "f1")
        XCTAssertEqual(collection.named("  Warm film ")?.id, "f1")
        XCTAssertNil(collection.named("Warm"))
        XCTAssertNil(collection.named(""))
    }

    func testRenameChangesTheNameUnlessItBelongsToAnotherFilter() throws {
        var collection = FilterCollection()
        collection.save(name: "Warm film", look: try makeLook(), id: "f1", now: referenceDate)
        collection.save(name: "Cool night", look: try makeLook(), id: "f2", now: referenceDate)

        XCTAssertTrue(collection.rename(id: "f1", to: "  Golden hour "))
        XCTAssertEqual(collection.filters.map(\.name), ["Golden hour", "Cool night"])
        XCTAssertNil(collection.named("Warm film"))

        XCTAssertFalse(collection.rename(id: "f1", to: "cool NIGHT"), "the name belongs to another filter")
        XCTAssertFalse(collection.rename(id: "f1", to: "   "), "an empty name is refused")
        XCTAssertFalse(collection.rename(id: "missing", to: "Anything"), "there is no such filter")
        XCTAssertEqual(collection.filters.map(\.name), ["Golden hour", "Cool night"])

        XCTAssertTrue(collection.rename(id: "f1", to: "GOLDEN HOUR"), "a filter may change the spelling of its own name")
        XCTAssertEqual(collection.filters.first?.name, "GOLDEN HOUR")
        XCTAssertEqual(collection.filters.first?.id, "f1")
    }

    func testDeleteRemovesOnlyThatFilter() throws {
        var collection = FilterCollection()
        collection.save(name: "Warm film", look: try makeLook(), id: "f1", now: referenceDate)
        collection.save(name: "Cool night", look: try makeLook(), id: "f2", now: referenceDate)
        collection.delete(id: "f1")
        XCTAssertEqual(collection.filters.map(\.id), ["f2"])
        collection.delete(id: "missing")
        XCTAssertEqual(collection.filters.map(\.id), ["f2"])
        // The name is free again.
        XCTAssertEqual(collection.save(name: "Warm film", look: try makeLook(), id: "f3", now: referenceDate)?.id, "f3")
        collection.delete(id: "f2")
        collection.delete(id: "f3")
        XCTAssertEqual(collection, FilterCollection())
    }

    func testACollectionRoundTripsThroughCodable() throws {
        var collection = FilterCollection()
        collection.save(name: "Warm film", look: try makeLook(), id: "f1", now: referenceDate)
        collection.save(name: "Plain", look: Look(state: EditingState(), defaults: PhotoDefaults()), id: "f2", now: referenceDate.addingTimeInterval(day))
        let data = try JSONEncoder().encode(collection)
        let restored = try JSONDecoder().decode(FilterCollection.self, from: data)
        XCTAssertEqual(restored, collection)
        XCTAssertEqual(restored.filters.map(\.createdAt), [referenceDate, referenceDate.addingTimeInterval(day)])
        XCTAssertEqual(try JSONDecoder().decode(FilterCollection.self, from: try JSONEncoder().encode(FilterCollection())), FilterCollection())
    }

    func testAFilterAppliedToAnotherPhotoKeepsThatPhotosFrame() throws {
        var collection = FilterCollection()
        collection.save(name: "Warm film", look: try makeLook(), id: "f1", now: referenceDate)
        let filter = try XCTUnwrap(collection.named("warm film"))
        let target = try edited(EditingState(defaults: targetDefaults)) { try $0.setCrop(["rotation": 180]) }
        let result = filter.look.applied(to: target, defaults: targetDefaults)
        XCTAssertEqual(result.crop.rotation, 180)
        XCTAssertEqual(result.value("contrast"), 15)
        XCTAssertEqual(result.changes(from: target).map(\.path).filter { $0.hasPrefix("crop") || $0.hasPrefix("detail") }, [])
    }
}
