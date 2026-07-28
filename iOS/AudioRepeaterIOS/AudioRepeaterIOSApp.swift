import SwiftUI
import UIKit

enum AudioRepeaterPreferences {
    static let ioAudio2RingOverwriteEnabled =
        "ioAudio2RingOverwriteEnabled"
    private static let defaultOffMigration =
        "ioAudio2RingOverwriteDefaultOffMigrationV1"

    static func registerDefaultsAndMigrate(
        _ defaults: UserDefaults = .standard
    ) {
        defaults.register(
            defaults: [ioAudio2RingOverwriteEnabled: false]
        )
        guard !defaults.bool(forKey: defaultOffMigration) else {
            return
        }

        // Earlier builds declared the UI default as true. Reset that legacy
        // value once so the visible switch and manual playback both start on
        // the ordinary AVAudioEngine path. Later user changes still persist.
        defaults.set(false, forKey: ioAudio2RingOverwriteEnabled)
        defaults.set(true, forKey: defaultOffMigration)
        defaults.synchronize()
        print(
            "AudioRepeaterIOS preference migration " +
                "ioAudio2RingOverwriteEnabled=false"
        )
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AudioRepeaterPreferences.registerDefaultsAndMigrate()
        application.isIdleTimerDisabled = true
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        application.isIdleTimerDisabled = true
    }
}

@main
struct AudioRepeaterIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
