# AudioRepeater iOS

SwiftUI iOS port of the Android AudioRepeater app.

## Features

- Pick multiple `.wav` files through the iOS Files picker.
- Works with Google Drive when Drive is enabled as a Files provider.
- Copies provider-backed files into the app cache before playback.
- Applies a global repeat count, then allows per-file repeat editing.
- Supports decimal delays for same-file repeats and different-file transitions.
- Uses `AVAudioEngine` and `AVAudioPlayerNode` to schedule audio and silence buffers continuously.
- Keeps the display awake while AudioRepeater is the active foreground app.
- Accepts one-shot remote playback requests uploaded from a Windows computer.

## Build On The Mac

The working copy used during remote testing is:

```bash
~/AudioRepeaterIOSWork/iOS
```

Build for simulator:

```bash
cd ~/AudioRepeaterIOSWork/iOS
xcodebuild \
  -project AudioRepeaterIOS.xcodeproj \
  -scheme AudioRepeaterIOS \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  build
```

Build for the currently connected simulator runtime, when Xcode destination
matching is healthy:

```bash
cd ~/AudioRepeaterIOSWork/iOS
xcodebuild \
  -project AudioRepeaterIOS.xcodeproj \
  -scheme AudioRepeaterIOS \
  -sdk iphonesimulator18.5 \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  build
```

Build for the wired iPhone after Developer Mode is enabled:

```bash
cd ~/AudioRepeaterIOSWork/iOS
xcodebuild \
  -project AudioRepeaterIOS.xcodeproj \
  -scheme AudioRepeaterIOS \
  -configuration Debug \
  -destination 'id=YOUR_DEVICE_UDID' \
  -derivedDataPath build/DeviceDerivedData \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

The iPhone 12 mini on iOS 16.3 uses the legacy MobileDevice path. Build
`ios-deploy` once on the Mac:

```bash
mkdir -p ~/AudioRepeaterIOSWork/tools
git clone https://github.com/ios-control/ios-deploy.git ~/AudioRepeaterIOSWork/tools/ios-deploy
cd ~/AudioRepeaterIOSWork/tools/ios-deploy
xcodebuild -target ios-deploy -configuration Release CODE_SIGNING_ALLOWED=NO
```

Install the signed app after a successful device build:

```bash
IOS_DEPLOY=~/AudioRepeaterIOSWork/tools/ios-deploy/build/Release/ios-deploy
APP_PATH=~/AudioRepeaterIOSWork/iOS/build/DeviceDerivedData/Build/Products/Debug-iphoneos/AudioRepeaterIOS.app
"$IOS_DEPLOY" \
  --id YOUR_DEVICE_UDID \
  --bundle "$APP_PATH" \
  --justlaunch
```

On the first install, trust the Apple Development profile under
`Settings > General > VPN & Device Management` on the iPhone.

## Remote Playback From Windows

The script copies local WAV files to the Mac, uploads them into the app
container, launches the app with the debugger attached, waits for playback to
finish, and prints the verified queue result.

```powershell
$files = @(
    'C:\Audio\example-1.wav',
    'C:\Audio\example-2.wav',
    'C:\Audio\example-3.wav',
    'C:\Audio\example-4.wav'
)

$playback = @{
    WavPath = $files
    RepeatCount = 10
    SameFileDelaySeconds = 0.1
    DifferentFileDelaySeconds = 0.25
}

.\iOS\scripts\play_remote.ps1 @playback
```

Successful completion includes one `repeat=10/10` line for every file and:

```text
AudioRepeaterIOS playQueue finish stopped=false
```
