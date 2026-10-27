import XCTest

final class PlaybackUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("These playback checks run only in the simulator.")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-test"]
        app.launch()
        XCTAssertTrue(app.buttons["playQueue"].waitForExistence(timeout: 10))
    }

    func testPlayAndStopBothBackends() throws {
        for path in ["AVAudioEngine", "RemoteIO"] {
            app.swipeDown()
            app.segmentedControls["playbackPath"].buttons[path].tap()
            app.buttons["playQueue"].tap()
            XCTAssertTrue(app.buttons["stopQueue"].isEnabled)
            // Give the real audio unit time to start, then exercise cancellation.
            sleep(2)
            XCTAssertFalse(app.alerts.firstMatch.exists, "Playback reported an error")
            app.buttons["stopQueue"].tap()
            let idle = NSPredicate(format: "enabled == true")
            expectation(for: idle, evaluatedWith: app.buttons["playQueue"])
            waitForExpectations(timeout: 10)
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        capture("Playback paths")
    }

    func testEffectsRecordingSettingsAndQueuePersist() throws {
        app.buttons["effectPicker"].tap()
        app.buttons["Equalizer"].tap()
        app.buttons["effectSettings"].tap()
        XCTAssertTrue(app.sliders["910 Hz"].waitForExistence(timeout: 5))
        app.sliders["910 Hz"].adjust(toNormalizedSliderPosition: 0.7)
        capture("Equalizer")
        app.buttons["Done"].tap()
        app.buttons["effectPicker"].tap()
        app.buttons["Dynamics Processing"].tap()
        app.buttons["effectSettings"].tap()
        XCTAssertTrue(app.sliders["Threshold"].waitForExistence(timeout: 5))
        capture("Dynamics")
        app.buttons["Done"].tap()
        let microphone = app.switches["recordMicrophone"]
        for _ in 0..<4 where !microphone.isHittable { app.swipeUp() }
        XCTAssertTrue(microphone.isHittable)
        if microphone.value as? String != "1" { microphone.tap() }
        capture("Recording and queue")
        app.terminate()
        app.launch()
        for _ in 0..<4 where !microphone.isHittable { app.swipeUp() }
        XCTAssertEqual(microphone.value as? String, "1")
        let item = app.staticTexts["Test tone.wav"]
        for _ in 0..<4 where !item.isHittable { app.swipeUp() }
        XCTAssertTrue(item.exists)
        // Leave the next test with microphone capture disabled.
        for _ in 0..<5 where !microphone.isHittable { app.swipeDown() }
        if microphone.value as? String == "1" { microphone.tap() }
        for _ in 0..<5 where !app.buttons["effectPicker"].isHittable { app.swipeDown() }
        app.buttons["effectPicker"].tap()
        app.buttons["Off"].tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
