# AudioRepeater iOS

The iOS app imports WAV files, queues repeats with configurable delays, and
plays them with AVAudioEngine or RemoteIO. Files providers such as Google Drive
can supply imported files. The app copies provider files before playback.

## Build

Windows users can build an unsigned iPhone IPA on GitHub Actions and install it
with Sideloadly. See [Windows build and installation](WINDOWS_INSTALL.md).
The shared `AudioRepeaterIOS` scheme builds only the app.
The current sources require Xcode 27 and the iOS 27 SDK for ScreenCaptureKit;
the deployment target remains iOS 16.

Open `AudioRepeaterIOS.xcodeproj` on a Mac with Xcode. Select your development
team in Signing & Capabilities. The project does not contain a team ID.
The deployment target is iOS 16. Features that require a newer system perform
runtime availability checks; ScreenCaptureKit audio capture requires iOS 27.

From this directory, build for the simulator:

```sh
xcodebuild -project AudioRepeaterIOS.xcodeproj \
  -scheme AudioRepeaterIOS -sdk iphonesimulator \
  -configuration Debug -derivedDataPath build/DerivedData build
```

For a device build, provide your own device and team identifiers:

```sh
export AUDIOREPEATER_DEVICE_ID=YOUR_DEVICE_UDID
export AUDIOREPEATER_TEAM_ID=YOUR_TEAM_ID
xcodebuild -project AudioRepeaterIOS.xcodeproj \
  -scheme AudioRepeaterIOS -configuration Debug \
  -destination "id=$AUDIOREPEATER_DEVICE_ID" \
  DEVELOPMENT_TEAM="$AUDIOREPEATER_TEAM_ID" \
  -derivedDataPath build/DeviceDerivedData \
  -allowProvisioningUpdates build
```

`scripts/build_install_stacktap.command` uses those two environment variables
to build and install the app. It resolves the project relative to the script.
Set `AUDIOREPEATER_IOS_ROOT` to override that directory, or
`AUDIOREPEATER_DEVELOPER_DIR` to select another Xcode installation.

## Remote playback from Windows

`scripts/play_remote.ps1` stages local WAV files on a Mac, uploads them into
the app container, and optionally launches playback. Its default Mac working
directory is `~/AudioRepeaterIOSWork`. It expects the built app under
`iOS/build/DeviceDerivedData` and, for the legacy deployment path, `ios-deploy`
under `tools/ios-deploy/build/Release` in that directory.

Specify the SSH host and device explicitly:

```powershell
.\scripts\play_remote.ps1 `
  -WavPath @('C:\Audio\tone.wav', 'C:\Audio\sweep.wav') `
  -MacHost 'your-mac-ssh-alias' `
  -DeviceId 'YOUR_DEVICE_UDID' `
  -RepeatCount 10 -SameFileDelaySeconds 0.1 -DifferentFileDelaySeconds 0.25
```

Use `-UseDeviceCtl` for devicectl.
Pass `-MacDeveloperDir` only when the Mac needs a non-default Xcode installation.
Do not commit local audio, device IDs, signing files, or SSH keys.

## Experimental IOAudio2 bridge

The bridge scripts support a separately configured research device. They are
optional and are not required for standard AVAudioEngine or RemoteIO playback.
The bridge expects these external files beside `ioaudio2_app_bridge.py`:

- `inject_wav_ioaudio2.py`
- `inject_wav_ioaudio2.js`
- `set_media_volume.js`

These dependencies are not included in this repository. The bridge validates
its configuration before it opens an SSH connection. Configure it on the Mac:

```sh
export AUDIOREPEATER_PHONE_HOST=your-device-hostname
export AUDIOREPEATER_SSH_KEY="$HOME/.ssh/your-device-key"
export AUDIOREPEATER_PYTHON="$HOME/.venvs/your-frida-env/bin/python"
python3 scripts/ioaudio2_app_bridge.py
```

`AUDIOREPEATER_RUNS` overrides the run directory. The default is
`~/.local/share/audiorepeater/ioaudio2-runs`. A run may contain audio, request
metadata, and logs. Keep this directory private.

`com.a2m.audiorepeater.ioaudio2bridge.plist.example` is a launchd template.
Replace `__HOME__` and `__PHONE_HOST__`, adjust the virtual environment and
bridge paths, and save the local file without `.example`. launchd does not
expand these placeholders. The local file is ignored by Git.

The `VolumeControl` test scheme changes hardware volume. Run it only when you
intend to change the volume on the connected device.
