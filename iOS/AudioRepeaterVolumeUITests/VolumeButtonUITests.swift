import XCTest

final class VolumeButtonUITests: XCTestCase {
    func testRaiseVolumeToMaximum() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(1)
        for _ in 0..<20 {
            XCUIDevice.shared.press(.volumeUp)
            usleep(100_000)
        }
        sleep(1)
    }

    func testSetVolumeToThreeQuarters() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(1)
        for _ in 0..<20 {
            XCUIDevice.shared.press(.volumeUp)
            usleep(100_000)
        }
        for _ in 0..<4 {
            XCUIDevice.shared.press(.volumeDown)
            usleep(100_000)
        }
        sleep(1)
    }

    func testCycleVolumeAndRestoreMaximum() throws {
        let app = XCUIApplication()
        app.launch()
        sleep(1)
        for _ in 0..<20 {
            XCUIDevice.shared.press(.volumeDown)
            usleep(100_000)
        }
        sleep(3)
        for _ in 0..<20 {
            XCUIDevice.shared.press(.volumeUp)
            usleep(100_000)
        }
        sleep(1)
    }
}
