import XCTest

/// The main flow, against a sample photo and a played-back model (-ui-testing): ask for an edit,
/// watch the assistant work and reply, open a version, save a filter, take a photo. Elements are
/// found by accessibility identifier, never by text, so the same test runs in English and Italian.
/// Screenshots are kept in the result bundle and exported by CI, which is how the app is reviewed
/// without a Mac.
final class OscuruUITests: XCTestCase {
    @MainActor
    func testEditingAPhotoWithTheAssistant() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        // The library, with the sample photo.
        let photo = element(app, "library.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 60))
        capture("01-library")
        photo.tap()

        // The thread: the original, and a place to say what you want.
        let field = element(app, "composer.field")
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "thread.original").waitForExistence(timeout: 30))
        capture("02-photo")

        // An instruction. The assistant works, the photo changes, then it replies in the thread.
        field.tap()
        field.typeText("Make it cinematic and recover the sky")
        capture("03-typing")
        element(app, "composer.send").tap()
        XCTAssertTrue(element(app, "composer.stop").waitForExistence(timeout: 30))
        capture("04-working")
        // Words sent while it works join its work between two steps.
        field.tap()
        field.typeText("Keep the sky blue")
        element(app, "composer.send").tap()
        capture("04b-sent-while-working")
        XCTAssertTrue(element(app, "thread.reply").waitForExistence(timeout: 120), "the assistant replies")
        // Done: the words may have joined the run or started a second one, so wait until nothing is working.
        func idle() -> Bool { !element(app, "composer.stop").exists && !element(app, "thread.working").exists }
        XCTAssertTrue(waitUntil(timeout: 180) { idle() && { sleep(2); return idle() }() }, "and is done")
        capture("05-reply")
        element(app, "thread.steps").tap()
        XCTAssertTrue(element(app, "steps.done").waitForExistence(timeout: 30))
        sleep(1)
        capture("06-steps")
        element(app, "steps.done").tap()

        // A version full screen.
        element(app, "thread.version").tap()
        XCTAssertTrue(element(app, "viewer.close").waitForExistence(timeout: 30))
        capture("07-viewer")
        element(app, "viewer.close").tap()

        // Styles, beside the composer: save this look as one, and see it tried on the photo.
        element(app, "composer.styles").tap()
        XCTAssertTrue(element(app, "styles.save").waitForExistence(timeout: 30))
        element(app, "styles.save").tap()
        let naming = app.alerts.firstMatch
        XCTAssertTrue(naming.waitForExistence(timeout: 30))
        let name = naming.textFields.firstMatch
        name.tap()
        name.typeText("Dusk")
        for label in ["Save", "Salva"] where naming.buttons[label].exists {
            naming.buttons[label].tap()
            break
        }
        XCTAssertTrue(element(app, "styles.item").waitForExistence(timeout: 30), "the style is saved")
        sleep(1)
        capture("08-styles")
        element(app, "composer.styles").tap()

        // Home: the style is there, with the way to make one from pictures.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        XCTAssertTrue(element(app, "library.style").waitForExistence(timeout: 30))
        capture("09-library")
        element(app, "library.newStyle").tap()
        XCTAssertTrue(element(app, "style.create").waitForExistence(timeout: 30))
        sleep(1)
        capture("09-new-style")
        element(app, "style.cancel").tap()

        // A style goes on photos by tapping it, then them.
        element(app, "library.style").tap()
        XCTAssertTrue(element(app, "library.applyStyle").waitForExistence(timeout: 30))
        photo.tap()
        capture("09-style-photos")
        element(app, "library.applyStyle").tap()
        XCTAssertTrue(element(app, "library.select").waitForExistence(timeout: 60), "applied, and back to the library")

        // Selecting, as in Photos: holding a photo starts it, with that photo chosen.
        photo.press(forDuration: 1)
        XCTAssertTrue(element(app, "library.endSelect").waitForExistence(timeout: 30), "holding a photo starts selecting")
        XCTAssertTrue(photo.isSelected, "with the photo held chosen")
        XCTAssertFalse(element(app, "composer.field").exists, "and without opening it")
        XCTAssertTrue(element(app, "library.selectDay").exists, "a whole day can be chosen from its header")
        capture("09-select")

        // Chosen photos combine into a collage, which opens like any photo.
        element(app, "library.combine").tap()
        XCTAssertTrue(element(app, "thread.original").waitForExistence(timeout: 90), "the collage opens as a new conversation")
        sleep(1)
        capture("09-collage")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "library.camera").waitForExistence(timeout: 30))
        element(app, "library.camera").tap()
        let shutter = element(app, "camera.shutter")
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        sleep(1)
        capture("10-camera")
        // Two ways to shoot; ProRAW zooms anywhere between the lenses, and the shot is framed that way.
        element(app, "camera.mode.proRAW").tap()
        XCTAssertTrue(element(app, "camera.lenses").waitForExistence(timeout: 10))
        element(app, "camera.viewfinder").pinch(withScale: 2.5, velocity: 1)
        sleep(1)
        capture("10b-camera-proraw")
        // The zoom buttons open into a dial that turns under the finger.
        element(app, "camera.lenses").press(forDuration: 0.1, thenDragTo: element(app, "camera.viewfinder"))
        capture("10c-camera-dial")
        shutter.tap()
        let lastShot = element(app, "camera.lastShot")
        XCTAssertTrue(waitUntil(timeout: 60) { lastShot.exists && lastShot.isEnabled }, "the shot lands in the library")
        sleep(1)
        capture("11-camera-shot")
        lastShot.tap()
        XCTAssertTrue(element(app, "thread.original").waitForExistence(timeout: 30), "the shot opens as a new conversation")
        sleep(2)
        capture("12-camera-photo")

        // Settings.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        element(app, "library.settings").tap()
        XCTAssertTrue(element(app, "settings.connected").waitForExistence(timeout: 30))
        capture("13-settings")

        // Signed out: one button to sign in, and the other ways on their own page.
        element(app, "settings.disconnect").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30))
        for label in ["Disconnect", "Scollega"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            break
        }
        XCTAssertTrue(element(app, "settings.signIn").waitForExistence(timeout: 30))
        capture("14-signed-out")
        element(app, "settings.other").tap()
        XCTAssertTrue(element(app, "settings.key").waitForExistence(timeout: 30))
        capture("15-other-ways")

        // Share, last, in a fresh launch: it ends in the system's share sheet.
        app.terminate()
        app.launch()
        XCTAssertTrue(photo.waitForExistence(timeout: 60))
        photo.tap()
        let share = element(app, "share")
        XCTAssertTrue(share.waitForExistence(timeout: 30))
        // Saving to Photos is its own button beside Share. (Not tapped: the system would ask for access.)
        XCTAssertTrue(element(app, "save").exists, "a photo can be saved to Photos in one tap")
        share.tap()
        let developed = element(app, "share.developed")
        XCTAssertTrue(developed.waitForExistence(timeout: 30))
        capture("16-share")
        developed.tap()
        _ = app.otherElements["ActivityListView"].waitForExistence(timeout: 30)
        capture("17-share-sheet")
        XCTAssertFalse(app.alerts.firstMatch.exists, "the photo was developed for sharing")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
