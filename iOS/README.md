# AudioRepeater iOS

The iOS app imports WAV files, queues repeats with configurable delays, and
plays them with AVAudioEngine or RemoteIO. Files providers such as Google Drive
can supply imported files. The app copies provider files before playback.

## Playback controls

The screen has Playback, Playback effects, Playback output, Recording, and Queue
sections. Play, Stop, and the current file/repeat status stay at the bottom.

- Choose AVAudioEngine or RemoteIO. The experimental IOAudio2 bridge remains
  available under Experimental bridge and requires its separate Mac setup.
- AVAudioEngine supports a five-band parametric Equalizer or Apple's broadband
  Dynamics Processor with an optional Peak Limiter. EQ centers are 60, 230,
  910, 3600, and 14000 Hz. Each band has a one-octave bandwidth and a -15 to
  +15 dB gain range. Effects are bypassed for RemoteIO and the IOAudio2 bridge.
- Dynamics controls expose threshold, headroom, attack, release, and overall
  gain. These are Apple's native parameters. They do not reproduce Android's
  three-band Dynamics Processing or its compression-ratio and limiter-ceiling
  controls.
- Select System, Speaker, or Receiver output. System follows the current
  iOS route. Speaker and Receiver require a compatible play-and-record session;
  playback reports an error if the requested built-in output is unavailable.
  The screen shows the active route, sample rate, and session mode.
- Select a session mode for normal playback. Microphone recording uses
  measurement mode unless a voice-chat mode is selected. Receiver and Speaker
  also constrain the session mode. The screen shows the effective mode.
- Enable Record microphone with playback to save 48 kHz mono PCM16 WAV files.
  iOS requests microphone permission when playback starts. Measurement mode
  minimizes input processing; it does not guarantee Android UNPROCESSED input.
  Chat modes request their session policy instead of measurement mode.
- On iOS 27 or later, Capture app audio opens the ScreenCaptureKit picker and
  saves a separate CAF file. This is separate from acoustic microphone capture.
- Open Recordings to share WAV/CAF files or add a recorded WAV to the queue.
  Recordings are also available in Files under On My iPhone > AudioRepeater >
  Recordings and through iTunes file sharing.
- Select or deselect all queue items, set repeats and delays, and use Edit to
  reorder the queue. Imported files, queue order, enable states, repeats,
  delays, and playback settings persist after relaunch. Restoring the queue
  does not start playback.

Imports and the saved queue live in Application Support. New recordings live
in Documents/Recordings. These directories are excluded from iCloud backup.
Removing an imported queue item deletes its owned copy. Removing a pinned,
remote, or recorded item from the queue keeps its original file. Export audio
before uninstalling the app. Phone calls and removal of an output device stop
playback and finalize microphone recording.

iOS does not expose Android's ALSA, AAudio, AudioTrack Usage, or ContentType
APIs. This app uses native iOS playback paths and AVAudioSession controls.

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

The existing `remote-playback.json` contract still supports its original
experimental AVAudioEngine fields. Requests without `processing` keep their
legacy speaker-only validation and do not inherit manual UI settings.
An optional `processing` object accepts the following native settings:

```json
{
  "files": [{"fileName": "tone.wav", "repeatCount": 2}],
  "sameFileDelaySeconds": 0.1,
  "differentFileDelaySeconds": 0.25,
  "processing": {
    "path": "avAudioEngine",
    "effect": "equalizer",
    "equalizerGains": [0, 0, 3, 0, 0],
    "output": "speaker",
    "sessionMode": "default",
    "recordMicrophone": false
  }
}
```

Omitted processing fields use defaults. A top-level `playbackPath` overrides
`processing.path`. A top-level `recordMicrophone` overrides the corresponding
processing flag. The five EQ gains are in dB. Dynamics fields are `thresholdDB`,
`headroomDB`, `attackMS`, `releaseMS`, `masterGainDB`, and `peakLimiter` inside
`processing.dynamics`. `masterGainDB` maps to Apple's Overall Gain parameter.
When `processing` is present, its selected effect replaces the legacy single-band
EQ settings. The remote log records the processing object and effective mode.
New microphone recordings go to Documents/Recordings. Legacy system-capture
file names and existing remote log locations remain supported.

## Verification

The iOS IPA workflow runs native Release compilation, checks settings and
queue persistence, tests legacy and extended remote manifests, and renders
audio offline to check that EQ, dynamics, and the limiter affect the signal.
Enable **run_ui_tests** when dispatching the workflow to run `PlaybackUITests`
from the existing UI-test target in an iPhone simulator. The hardware-volume
tests are excluded from simulator compilation. Normal IPA builds keep the
native settings and rendered-audio checks and omit the slower simulator run.
Simulator screenshots are uploaded as `AudioRepeaterIOS-simulator`.
ScreenCaptureKit is unavailable in the simulator SDK, so the simulator omits
its capture switch and reports unsupported capture requests as errors.
The simulator checks do not verify a physical iPhone's output route,
microphone, ScreenCaptureKit permissions, or acoustic response.

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
