import XCTest

@testable import OscuruCore

final class CollageAndSplitTests: XCTestCase {
    func testStartingLayoutsFillTheCanvasWithoutHoles() {
        for aspects in [[1.5], [0.75, 0.75], [1.5, 1.5], [0.75, 0.75, 0.75], [1.5, 1.5, 1.5], [1, 1, 1, 1, 1], Array(repeating: 1.5, count: 12)] {
            let layout = CollageLayout.automatic(aspects: aspects)
            XCTAssertEqual(layout.cells.map(\.piece), Array(0..<aspects.count), "every piece once, in order")
            let covered = layout.cells.reduce(0) { $0 + $1.width * $1.height }
            XCTAssertEqual(covered, 1, accuracy: 1e-9, "\(aspects.count) pieces cover the canvas exactly")
            for cell in layout.cells {
                XCTAssertLessThanOrEqual(cell.x + cell.width, 1 + 1e-9)
                XCTAssertLessThanOrEqual(cell.y + cell.height, 1 + 1e-9)
            }
        }
        XCTAssertEqual(CollageLayout.automatic(aspects: [0.75, 0.75]).aspect, 1.5, "two portraits side by side")
        XCTAssertEqual(CollageLayout.automatic(aspects: [1.5]).canvasSize.width, 4096)
        XCTAssertEqual(CollageLayout.automatic(aspects: [1.5]).canvasSize.height, 2731)
    }

    func testTheGapIsTheSameBetweenPiecesAndAroundThem() {
        var layout = CollageLayout.automatic(aspects: [0.75, 0.75])
        layout.gap = 0.01
        let frames = layout.frames(width: 1000, height: 500)
        XCTAssertEqual(frames[0].x, 10, accuracy: 1e-9, "left edge")
        XCTAssertEqual(frames[1].x - (frames[0].x + frames[0].width), 10, accuracy: 1e-9, "between")
        XCTAssertEqual(1000 - (frames[1].x + frames[1].width), 10, accuracy: 1e-9, "right edge")
        XCTAssertEqual(frames[0].y, 10, accuracy: 1e-9)
        XCTAssertEqual(frames[0].height, 480, accuracy: 1e-9)
    }

    func testAPieceIsCroppedToFillItsCellAroundItsFocus() {
        var cell = CollageLayout.Cell(piece: 0, x: 0, y: 0, width: 1, height: 1)
        // A 2:1 piece in a square cell shows half its width, from the middle.
        var window = cell.window(pieceWidth: 2000, pieceHeight: 1000, cellWidth: 500, cellHeight: 500)
        XCTAssertEqual(window.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(window.height, 1000, accuracy: 1e-9)
        XCTAssertEqual(window.x, 500, accuracy: 1e-9)
        // Focus on the left: as far left as it goes, never past the edge.
        cell.focus = [0, 0.5]
        window = cell.window(pieceWidth: 2000, pieceHeight: 1000, cellWidth: 500, cellHeight: 500)
        XCTAssertEqual(window.x, 0, accuracy: 1e-9)
        cell.zoom = 2
        window = cell.window(pieceWidth: 2000, pieceHeight: 1000, cellWidth: 500, cellHeight: 500)
        XCTAssertEqual(window.width, 500, accuracy: 1e-9, "twice the zoom shows half as much")
    }

    func testALayoutIsChangedLikeAnyOtherSettingAndOnlyOnACollage() throws {
        let made = CollageLayout.automatic(aspects: [1, 1, 1])
        var state = EditingState(defaults: PhotoDefaults(layout: made))
        try state.setLayout(["gap": 0, "background": "#000000"], pieces: 3)
        XCTAssertEqual(state.layout?.gap, 0)
        XCTAssertEqual(state.layout?.cells, made.cells, "cells not given stay")
        try state.setLayout(["cells": [["piece": 2, "x": 0, "y": 0, "width": 1, "height": 1, "focus": [0.3, 0.5]]]], pieces: 3)
        XCTAssertEqual(state.layout?.cells.map(\.piece), [2])

        XCTAssertThrowsError(try state.setLayout(["cells": [["piece": 3, "x": 0, "y": 0, "width": 1, "height": 1]]], pieces: 3))
        XCTAssertThrowsError(try state.setLayout(["cells": [["piece": 0, "x": 0.5, "y": 0, "width": 0.8, "height": 1]]], pieces: 3)) { error in
            XCTAssertTrue("\(error)".contains("leaves the canvas"))
        }
        XCTAssertThrowsError(try state.setLayout(["background": "white"], pieces: 3))
        var photo = EditingState()
        XCTAssertThrowsError(try photo.setLayout(["gap": 0], pieces: 0)) { error in
            XCTAssertTrue("\(error)".contains("not a collage"))
        }

        // Kept, compared, reset and read back like the rest of the settings.
        XCTAssertEqual(try JSONDecoder().decode(EditingState.self, from: JSONEncoder().encode(state)), state)
        XCTAssertEqual(try EditingState(json: state.json), state)
        XCTAssertTrue(state.changes(from: EditingState(defaults: PhotoDefaults(layout: made))).contains { $0.path.hasPrefix("layout.") })
        try state.reset(section: "layout", defaults: PhotoDefaults(layout: made))
        XCTAssertEqual(state.layout, made)
        XCTAssertNil(EditingState().json["layout"], "a photo has no layout")
    }

    func testSplittingMakesEqualPartsOrTheRegionsAsked() throws {
        let three = try FrameRegion.parts(["columns": 3])
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(three[2].x, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(try FrameRegion.parts(["columns": 2, "rows": 2]).map(\.y), [0, 0, 0.5, 0.5])
        XCTAssertEqual(try FrameRegion.parts([["x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5]]).count, 1)
        XCTAssertThrowsError(try FrameRegion.parts(["columns": 1]))
        XCTAssertThrowsError(try FrameRegion.parts([["x": 0.6, "y": 0, "width": 0.6, "height": 1]]))
        XCTAssertThrowsError(try FrameRegion.parts("thirds"))
    }

    func testAPartKeepsTheEditsWhereTheyWereOnThePicture() throws {
        var state = EditingState()
        try state.adjust(["exposureEV": 0.5])
        try state.setCrop(["x": 0.1, "width": 0.8])
        try state.setLocal(name: "sun", settings: ["mask": ["area": ["type": "radial", "x": 0.75, "y": 0.5, "width": 0.2, "height": 0.4]], "adjust": ["exposureEV": 0.3]])
        let right = try state.part(FrameRegion(x: 0.5, y: 0, width: 0.5, height: 1), frameAspect: state.frameAspect(photoWidth: 3000, photoHeight: 2000))
        XCTAssertEqual(right.value("exposureEV"), 0.5, "edits come along")
        XCTAssertEqual(right.crop.x, 0.5, accuracy: 1e-9, "the right half of the crop")
        XCTAssertEqual(right.crop.width, 0.4, accuracy: 1e-9)
        let sun = right.local[0].mask.area
        XCTAssertEqual(sun.x, 0.5, accuracy: 1e-9, "the sun is in the middle of the right half")
        XCTAssertEqual(sun.width, 0.4, accuracy: 1e-9, "and as big on the picture as it was")
        XCTAssertThrowsError(try state.part(FrameRegion(x: 0, y: 0, width: 0.03, height: 1), frameAspect: 1.8)) { error in
            XCTAssertTrue("\(error)".contains("smallest crop"))
        }
    }
}
