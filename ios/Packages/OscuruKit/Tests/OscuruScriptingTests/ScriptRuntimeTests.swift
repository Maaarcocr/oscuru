import Foundation
import OscuruCore
import XCTest

@testable import OscuruScripting

/// A stand-in for the app: the "photo" is a flat grey whose brightness follows the exposure setting.
private final class FakeHost: ScriptHost, @unchecked Sendable {
    var filters = FilterCollection()
    var imageRequests: [(state: EditingState, region: ScriptRegion?, maxEdge: Int)] = []
    var analysisCount = 0
    var failRendering = false

    func analysis(of state: EditingState) -> ImageAnalysis? {
        if failRendering { return nil }
        analysisCount += 1
        let level = UInt8(max(0, min(255, (100 * pow(2, state.value("exposureEV"))).rounded())))
        var pixels = Data()
        for _ in 0..<16 { pixels.append(contentsOf: [level, level, level, 255]) }
        return ImageAnalysis(pixels: pixels, width: 4, height: 4)
    }

    func image(of state: EditingState, region: ScriptRegion?, maxEdge: Int) -> Data? {
        if failRendering { return nil }
        imageRequests.append((state, region, maxEdge))
        return Data("jpeg-\(imageRequests.count)".utf8)
    }

    func filterNames() -> [String] { filters.filters.map(\.name) }
    func look(named name: String) -> Look? { filters.named(name)?.look }
    func saveFilter(name: String, look: Look) -> Bool { filters.save(name: name, look: look, id: UUID().uuidString, now: Date(timeIntervalSince1970: 0)) != nil }
    func deleteFilter(name: String) -> Bool {
        guard let filter = filters.named(name) else { return false }
        filters.delete(id: filter.id)
        return true
    }
}

final class ScriptRuntimeTests: XCTestCase {
    private var host: FakeHost!
    private var runtime: ScriptRuntime!
    private let info: PhotoInfo = {
        var info = PhotoInfo(
            fileName: "IMG_0001.DNG", typeIdentifier: "com.adobe.raw-image", isRaw: true, width: 4032, height: 3024,
            defaults: PhotoDefaults(temperature: 5200, tint: 8, sharpening: 40, noiseReduction: 50, colorNoiseReduction: 50))
        info.iso = 64
        return info
    }()

    override func setUp() {
        host = FakeHost()
        runtime = ScriptRuntime(host: host)
    }

    private func run(_ code: String, state: EditingState? = nil, before: EditingState? = nil, cancelled: @escaping @Sendable () -> Bool = { false }) async -> ScriptOutcome {
        let start = state ?? EditingState(defaults: info.defaults)
        return await runtime.run(ScriptRequest(code: code, state: start, revision: 7, info: info, before: before ?? start), isCancelled: cancelled)
    }

    // MARK: Editing

    func testAScriptChangesTheSettingsAndListsWhatChanged() async {
        let outcome = await run(
            """
            const image = photo.current;
            image.adjust({ exposureEV: 0.35, highlights: -40 });
            image.curves.set("rgb", [[0, 0.03], [0.5, 0.5], [1, 0.98]]);
            image.hsl.adjust("blue", { saturation: -15, luminance: -10 });
            image.grading.set("shadows", { hue: 215, saturation: 0.12 });
            """)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.state.value("exposureEV"), 0.35)
        XCTAssertEqual(outcome.state.hsl["blue"], ["hue": 0, "saturation": -15, "luminance": -10])
        XCTAssertEqual(
            outcome.changes.map(\.path),
            ["global.exposureEV", "global.highlights", "curves.rgb", "hsl.blue.luminance", "hsl.blue.saturation", "grading.shadows.hue", "grading.shadows.saturation"])
    }

    func testChangesAreRelativeToTheStateAndStartFromAsShotWhiteBalance() async {
        let outcome = await run(
            """
            const { global, revision } = photo.current.getState();
            photo.current.adjust({ temperature: global.temperature + 400, exposureEV: global.exposureEV + 0.25 });
            revision;
            """)
        XCTAssertEqual(outcome.state.value("temperature"), 5600)
        XCTAssertEqual(outcome.state.value("exposureEV"), 0.25)
        XCTAssertEqual(outcome.returnValue, "7")
    }

    func testAnErrorDiscardsEverythingAndReportsWhere() async {
        let outcome = await run("photo.current.adjust({ contrast: 30 });\nconsole.log('about to fail');\nphoto.current.adjust({ exposureEV: 99 });")
        XCTAssertEqual(outcome.error?.name, "RangeError")
        XCTAssertEqual(outcome.error?.message, "adjust.exposureEV must be between -5 and 5, got 99")
        XCTAssertEqual(outcome.error?.line, 3)
        XCTAssertEqual(outcome.state.value("contrast"), 0)
        XCTAssertTrue(outcome.changes.isEmpty)
        XCTAssertEqual(outcome.logs, ["about to fail"])
    }

    func testAScriptCanCatchAValidationErrorAndCarryOn() async {
        let outcome = await run(
            """
            try { photo.current.adjust({ saturation: 500 }); } catch (error) { console.log(error.name, error.message); }
            photo.current.adjust({ saturation: 20 });
            """)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.state.value("saturation"), 20)
        XCTAssertEqual(outcome.logs, ["RangeError adjust.saturation must be between -100 and 100, got 500"])
    }

    func testSyntaxErrorsAndUnknownNamesAreReported() async {
        let syntax = await run("photo.current.adjust({")
        XCTAssertEqual(syntax.error?.name, "SyntaxError")
        let unknown = await run("fetch('https://example.com')")
        XCTAssertEqual(unknown.error?.name, "ReferenceError")
        let missing = await run("photo.current.sharpen(3)")
        XCTAssertEqual(missing.error?.name, "TypeError")
    }

    func testRevertResetAndTheRestOfTheAPI() async {
        let outcome = await run(
            """
            const image = photo.current;
            image.adjust({ contrast: 20, temperature: 7000 });
            image.curves.set("red", [[0, 0.1], [1, 1]]);
            image.hsl.adjust("green", { hue: 10 });
            image.grading.set("highlights", { hue: 40, saturation: 0.1 });
            image.grading.configure({ balance: 0.3 });
            image.detail.set({ sharpening: 60 });
            image.crop({ x: 0.1, width: 0.8, angle: 1.5, rotation: 90 });
            const seen = [image.curves.get("red")[0][1], image.hsl.get("green").hue, image.grading.get("highlights").hue, image.detail.get().sharpening];
            image.curves.reset("red");
            image.hsl.reset();
            image.reset("color");
            image.commit();
            seen;
            """)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.returnValue, "[0.1,10,40,60]")
        XCTAssertEqual(outcome.state.curves["red"], [[0, 0], [1, 1]])
        XCTAssertEqual(outcome.state.hsl["green"]?["hue"], 0)
        XCTAssertEqual(outcome.state.value("temperature"), 5200)
        XCTAssertEqual(outcome.state.value("contrast"), 20)
        XCTAssertEqual(outcome.state.grading.balance, 0.3)
        XCTAssertEqual(outcome.state.detail["sharpening"], 60)
        XCTAssertEqual(outcome.state.crop.rotation, 90)

        let reverted = await run("photo.current.adjust({ contrast: 50 }); photo.current.revert(); photo.current.getState().global.contrast")
        XCTAssertEqual(reverted.returnValue, "0")
        XCTAssertTrue(reverted.changes.isEmpty)
    }

    func testMetadataIsWhatThePhotoReported() async {
        let outcome = await run("const m = photo.current.getMetadata(); [m.isRaw, m.iso, m.asShot.temperature, m.width, 'defaults' in m]")
        XCTAssertEqual(outcome.returnValue, "[true,64,5200,4032,false]")
    }

    // MARK: Looking and measuring

    func testStatisticsFollowTheScriptsOwnChanges() async {
        let outcome = await run(
            """
            const before = photo.current.getStatistics().meanLuminance;
            photo.current.adjust({ exposureEV: 1 });
            const after = photo.current.getStatistics().meanLuminance;
            const again = photo.current.getHistogram().highlightClipping;
            [before < 0.45, after > 0.7, again];
            """)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.returnValue, "[true,true,0]")
        // Measured once per distinct state, not once per call.
        XCTAssertEqual(host.analysisCount, 2)
    }

    func testShowQueuesPicturesOfTheCurrentBeforeAndOriginalPhoto() async {
        var before = EditingState(defaults: info.defaults)
        try! before.adjust(["contrast": 11])
        var start = before
        try! start.adjust(["contrast": 22])
        try! start.setCrop(["rotation": 90])
        let outcome = await run(
            """
            photo.current.adjust({ contrast: 33 });
            photo.show();
            photo.show("before");
            photo.show("original", { region: { x: 0.25, y: 0.25, width: 0.5, height: 0.5 }, maxEdge: 5000 });
            """, state: start, before: before)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.shown.count, 3)
        XCTAssertEqual(host.imageRequests.map { $0.state.value("contrast") }, [33, 11, 0])
        // The original keeps the framing, so it lines up with the edited photo.
        XCTAssertEqual(host.imageRequests[2].state.crop.rotation, 90)
        XCTAssertEqual(host.imageRequests[2].region, ScriptRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(host.imageRequests[0].maxEdge, Prompt.defaultImageEdge)
        XCTAssertEqual(host.imageRequests[2].maxEdge, Prompt.maxImageEdge)
        XCTAssertTrue(outcome.shown[0].label.contains("picture 1"))
        XCTAssertTrue(outcome.shown[2].label.contains("original"))
        XCTAssertTrue(outcome.shown[2].label.contains("region"))
        XCTAssertEqual(outcome.shown[1].jpeg, Data("jpeg-2".utf8))
    }

    func testShowRejectsBadArguments() async {
        let kind = await run("photo.show('negative')")
        XCTAssertEqual(kind.error?.name, "RangeError")
        let region = await run("photo.show('current', { region: { x: 0.8, y: 0, width: 0.5, height: 1 } })")
        XCTAssertTrue(region.error?.message.contains("inside the frame") ?? false)
        let option = await run("photo.show('current', { zoom: 2 })")
        XCTAssertTrue(option.error?.message.contains("no option \"zoom\"") ?? false)
    }

    func testARenderingFailureIsAnErrorTheScriptCanRead() async {
        host.failRendering = true
        let outcome = await run("photo.current.getStatistics()")
        XCTAssertEqual(outcome.error?.name, "Error")
        XCTAssertTrue(outcome.error?.message.contains("could not be rendered") ?? false)
    }

    // MARK: Filters

    func testFiltersCanBeSavedListedAppliedAndDeleted() async {
        let saved = await run(
            """
            photo.current.adjust({ contrast: 25, temperature: 5700 });
            photo.current.grading.set("shadows", { hue: 220, saturation: 0.1 });
            photo.filters.save("Warm film");
            photo.filters.list();
            """)
        XCTAssertNil(saved.error)
        XCTAssertEqual(saved.returnValue, "[\"Warm film\"]")

        var other = EditingState(defaults: info.defaults)
        try! other.setCrop(["rotation": 180])
        let applied = await run("photo.filters.apply('warm FILM'); photo.current.getState().global.contrast", state: other)
        XCTAssertEqual(applied.returnValue, "25")
        XCTAssertEqual(applied.state.value("temperature"), 5700)
        XCTAssertEqual(applied.state.grading.shadows["hue"], 220)
        XCTAssertEqual(applied.state.crop.rotation, 180)

        let missing = await run("photo.filters.apply('Nope')")
        XCTAssertTrue(missing.error?.message.contains("Saved filters: Warm film") ?? false)
        let deleted = await run("photo.filters.delete('Warm film'); photo.filters.list().length")
        XCTAssertEqual(deleted.returnValue, "0")
    }

    // MARK: The environment

    func testTheContextIsAREPL() async {
        _ = await run("var runs = 1; function double(x) { return x * 2 } globalThis.note = 'kept'; const local = 5; let other = 6;")
        let second = await run("const local = 50; runs += 1; [runs, double(21), note, local, typeof other]")
        XCTAssertNil(second.error)
        XCTAssertEqual(second.returnValue, "[2,42,\"kept\",50,\"undefined\"]")
    }

    func testAScriptWrittenAsAFunctionBodyStillRuns() async {
        let outcome = await run("photo.current.adjust({ contrast: 5 });\nreturn { ok: true };")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.returnValue, "{\"ok\":true}")
        XCTAssertEqual(outcome.state.value("contrast"), 5)
    }

    func testThereIsNothingToReachBesidesPhotoAndConsole() async {
        let outcome = await run(
            """
            [typeof fetch, typeof XMLHttpRequest, typeof require, typeof process, typeof setTimeout, typeof __oscuruNative, typeof importScripts]
            """)
        XCTAssertEqual(outcome.returnValue, "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]")
        let frozen = await run("photo.current.adjust = 1; photo.filters.list = 2; [typeof photo.current.adjust, typeof photo.filters.list]")
        XCTAssertEqual(frozen.returnValue, "[\"function\",\"function\"]")
        let rebound = await run("photo = null; typeof photo.current.adjust")
        XCTAssertEqual(rebound.returnValue, "\"function\"")
    }

    func testConsoleOutputAndReturnValuesComeBackAsText() async {
        let outcome = await run("console.log('iso', photo.current.getMetadata().iso, { a: [1, 2] }, null); console.warn(new Error('careful')); 'done'")
        XCTAssertEqual(outcome.logs, ["iso 64 {\"a\":[1,2]} null", "Error: careful"])
        XCTAssertEqual(outcome.returnValue, "\"done\"")
        let nothing = await run("photo.current.adjust({ contrast: 1 });")
        XCTAssertNil(nothing.returnValue)
    }

    // MARK: Stopping

    func testACancelledScriptStopsAtItsNextAPICallAndChangesNothing() async {
        let flag = Flag()
        let outcome = await run(
            "photo.current.adjust({ contrast: 10 }); for (;;) { photo.current.getState(); }",
            cancelled: {
                flag.tick()
                return flag.count > 20
            })
        XCTAssertEqual(outcome.error?.name, "Cancelled")
        XCTAssertEqual(outcome.state.value("contrast"), 0)
    }

    func testAnEndlessLoopIsAbandonedAndTheNextScriptGetsAFreshContext() async {
        runtime.abandonAfter = 0.3
        let flag = Flag()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag.set() }
        let started = Date()
        let stuck = await run("var leftover = 1; while (true) {}", cancelled: { flag.isSet })
        XCTAssertEqual(stuck.error?.name, "Cancelled")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let next = await run("typeof leftover")
        XCTAssertNil(next.error)
        XCTAssertEqual(next.returnValue, "\"undefined\"")
    }

    func testALongScriptIsNotCutShort() async {
        let outcome = await run("let total = 0; for (let i = 0; i < 3000000; i++) { total += i % 7; } total")
        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.returnValue, "8999994")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private(set) var count = 0

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func tick() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
