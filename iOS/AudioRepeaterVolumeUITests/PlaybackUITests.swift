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
            playBrieflyAndStop()
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
        playBrieflyAndStop()
        app.buttons["effectPicker"].tap()
        app.buttons["Dynamics Processing"].tap()
        app.buttons["effectSettings"].tap()
        XCTAssertTrue(app.sliders["Threshold"].waitForExistence(timeout: 5))
        capture("Dynamics")
        app.buttons["Done"].tap()
        playBrieflyAndStop()
        let microphone = app.switches["recordMicrophone"]
        reveal(microphone)
        if microphone.value as? String != "1" { tapSwitchThumb(microphone) }
        capture("Microphone toggle")
        XCTAssertEqual(microphone.value as? String, "1", "The switch must change before testing persistence")
        capture("Recording and queue")
        app.terminate()
        app.launch()
        reveal(microphone)
        XCTAssertEqual(microphone.value as? String, "1")
        let item = app.staticTexts["Test tone.wav"]
        reveal(item)
        XCTAssertTrue(item.exists)
        // Leave the next test with microphone capture disabled.
        reveal(microphone)
        if microphone.value as? String == "1" { tapSwitchThumb(microphone) }
        XCTAssertEqual(microphone.value as? String, "0")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func playBrieflyAndStop() {
        app.buttons["playQueue"].tap()
        XCTAssertTrue(app.buttons["stopQueue"].isEnabled)
        sleep(2)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Playback reported an error")
        app.buttons["stopQueue"].tap()
        let idle = NSPredicate(format: "enabled == true")
        expectation(for: idle, evaluatedWith: app.buttons["playQueue"])
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func reveal(_ element: XCUIElement) {
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.buttons["playQueue"].frame.minY - 12
        let middle = (top + bottom) / 2
        for _ in 0..<10 {
            var distance: CGFloat = -120
            if element.exists {
                let frame = element.frame
                if element.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
                distance = frame.midY < middle ? 120 : -120
                print("Reveal \(element.identifier): frame=\(frame), visible=\(top)...\(bottom)")
            }
            // A full-screen swipe can move a row from below the footer to above
            // the navigation bar. Short drags keep the row inside the viewport.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: middle))
            let end = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: middle + distance))
            start.press(forDuration: 0.15, thenDragTo: end)
        }
        XCTFail("Could not reveal the complete control above the fixed playback bar: \(element)")
    }

    private func tapSwitchThumb(_ element: XCUIElement) {
        // SwiftUI exposes the whole form row as the switch's accessibility
        // frame. Its center is the label; the switch itself is at the trailing edge.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
}
