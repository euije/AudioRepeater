# Direct ALSA playback

AudioRepeater has two Direct ALSA options:

1. `Direct ALSA (root / TinyALSA pcm_write)` — requires an existing root shell
   (`su`). See "root / TinyALSA" section below.
2. `Direct ALSA (init-hijack)` — Pixel 4 only; obtains root itself via
   CVE-2023-33107 (init code-page hijack) and drives the TinyALSA helper through
   the resulting root reverse shell. See "init-hijack" section below.

- Unchecked (both): the existing AudioTrack path is used, unless the separate AAudio
  EXCLUSIVE option is selected.
- The two Direct ALSA options and AAudio EXCLUSIVE are mutually exclusive in the UI.

## Simultaneous UNPROCESSED microphone recording

Enable `마이크 동시 녹음 (UNPROCESSED)` before starting the queue to record the
device microphone while any playback path, including Direct ALSA, is active.
The app requests `MediaRecorder.AudioSource.UNPROCESSED` without falling back to
a processed input source and records a single 48 kHz mono PCM16 WAV for the
whole enabled queue. Recordings are stored in the app-specific external Music
directory under `AudioRepeater/recordings`.

ADB-launched tests can enable the option with:

```text
--ez debugRecordUnprocessed true
```

Successful logs contain `micRecording start` and `micRecording complete` with
the requested and actual source, device capability property, format, byte count,
duration, and output path.

## init-hijack (Pixel 4 locked bootloader, no `su`)

`--ez debugUseDirectAlsaInitHijack true` / `false`.

When enabled, the app acquires root on a bootloader-locked Pixel 4 (`flame`,
`TP1A.221005.002.B2`) without `su`:

1. The APK bundles the CVE-2023-33107 exploit as two native libraries:
   - `liba2m_perm.so` — SELinux permissive phase (Stage 2, PTE mirror of
     `selinux_state` + zeroing the enforcing byte). Runs in a forked child that
     sleeps forever while holding the corrupted PTE.
   - `liba2m_s34.so` — init-hijack phase (Stage 3+4): aliases init's
     `/system/lib64/libbase.so` `LogLine` and writes the 287-byte reverse shell,
     then triggers init (orphaned child SIGCHLD) so the shellcode runs as pid 1.
2. The app binds `127.0.0.1:1337` on the device and the root shell connects back
   to it directly (no `adb reverse`, no host listener). Clear any existing
   `adb reverse tcp:1337 tcp:1337` first — it would hold the port.
3. The app verifies `uid=0(root)`, then plays one aggregate WAV per listed
   signal through the shell:
   `tinymix route enable -> tinyplay_pcm_write <aggregate> -D 0 -d 13 -p 1024 -n 2 -> tinymix route disable`.

Scratch files (`cand`, `attr`, `shellcode`, `recover`, `stage.txt`, `leak.log`)
are written under the app's `files/init-hijack/` directory; the aggregate WAVs
are built in the app cache (repeats + delays baked in, same as the root/TinyALSA
path).

The init-hijack exploit is probabilistic (~25% per attempt); the app retries the
permissive phase (2x) and the init-hijack phase (3x). Reliability is best on a
settled heap (idle for several minutes after boot, MemAvailable > 2 GB). On a
successful run the app logs:

```text
requestedPath=Direct ALSA init-hijack
A2M_INIT_HIJACK_PERMISSIVE child pid=<pid>
A2M_INIT_HIJACK_PERMISSIVE_OK
A2M_INIT_HIJACK_S34 child pid=<pid>
A2M_INIT_HIJACK_ACCEPT accepted#1 root=...
uid=0(root) gid=0(root) groups=0(root),3009(readproc) context=u:r:toolbox:s0
A2M_INIT_HIJACK_ROOT ...
A2M_ALSA_ROUTE_ENABLED
A2M_ALSA_PCM_COMPLETE file=<name> node=/dev/snd/pcmC0D13p ... api=pcm_write rootVerified=true
A2M_ALSA_ROUTE_DISABLED
ALSA stream complete ... api=pcm_write rootVerified=true path=init-hijack
playQueue finish stopped=false
```

The permissive child holds a corrupted PTE for as long as it (and the app
process) lives. Killing the app process afterwards can trigger a kernel
`BUG: Bad page map` panic -> reboot, which returns SELinux to Enforcing. This is
the same known behavior as the host-driven exploit sessions.

Only `flame` (Pixel 4, this exact build) is supported. The TinyALSA helper and
tinymix route are the same verified files used by the root/TinyALSA path.

## root / TinyALSA (requires `su`)

- Unchecked: the existing AudioTrack path is used, unless the separate AAudio
  EXCLUSIVE option is selected.
- Checked: for integer PCM 16/24/32-bit WAV input, AudioRepeater prepares one
  WAV containing the requested repeats and delays while preserving the source
  sample rate, channel count, bit depth, and sample bytes. It starts a
  silence-only AudioTrack route helper and runs the verified TinyALSA helper
  as root.
- The test waveform is written by TinyALSA to the ALSA PCM device. AudioTrack
  carries silence only and keeps the vendor-calibrated speaker backend and
  amplifiers active.
- Direct ALSA and AAudio EXCLUSIVE are mutually exclusive in the UI.

ADB control:

```text
--ez debugUseDirectAlsa true
--ez debugUseDirectAlsa false
```

Controlled ablation extras (ADB-launched tests only):

```text
--ez debugUseLowLatencyAudioTrack true
--ez debugForceStereoRouteAssist true
--ei debugDirectAlsaPcmDevice 1
--ei debugDirectAlsaPcmDevice 0
--ei debugDirectAlsaPcmDevice 9
```

`debugUseLowLatencyAudioTrack` requests the AudioTrack low-latency performance
mode so a framework path can be compared with direct playback on ZFlip3 PCM9.
`debugForceStereoRouteAssist` keeps the silence-only route helper at PCM16
stereo while mono/stereo and S16/S24 payloads are varied. On ZFlip3 only,
`debugDirectAlsaPcmDevice=0` selects the experimental MultiMedia1/PCM0 profile;
its route helper uses the low-latency PCM9 path so PCM0 remains available for
the direct payload. Omitting the extra retains the verified normal profile.

Supported device profiles:

| Device | PCM | FE-to-BE route |
| --- | --- | --- |
| Pixel 4 (`flame`) | `/dev/snd/pcmC0D13p` | `TERT_TDM_RX_0 Audio Mixer MultiMedia5` |
| Pixel 7 (`panther`) | `/dev/snd/pcmC0D1p` | `TDM_0_RX Mixer EP2` |
| Pixel 10 (`frankel`) | `/dev/snd/pcmC0D1p` | `TDM_0_RX Mixer EP2` |
| Redmi Note 7 (`lavender`) | `/dev/snd/pcmC0D13p` | `PRI_MI2S_RX Audio Mixer MultiMedia5` |
| Galaxy S10 (`beyond1`) | `/dev/snd/pcmC0D1p` | `ABOX RDMA1_EN` with the silence-only Samsung speaker route helper |
| ZFlip3 (`b2q`) | `/dev/snd/pcmC0D9p` | `PRI_TDM_RX_0 Audio Mixer MultiMedia5` |
| ZFlip3 ablation (`debugDirectAlsaPcmDevice=0`) | `/dev/snd/pcmC0D0p` | `PRI_TDM_RX_0 Audio Mixer MultiMedia1` |

The common `pcm_write` helper must be installed at the following path, except
for the Pixel 10 Android 17 mmap profile described below:

```text
/data/local/tmp/audiorepeater_alsa/tinyplay_pcm_write
```

Galaxy S10 RDMA1 consumes stereo frames. Mono PCM16 sources are duplicated to
identical left/right samples in the temporary Direct ALSA aggregate so playback
duration and sample timing remain unchanged; the registered source WAV remains
mono PCM16.

Required SHA-256:

```text
a4c29d738c76e73c32b4ac7940de5a72974128c14f6a44aacdf9e82e2b8cf785
```

The helper is the AOSP Android 13 TinyALSA build whose playback loop calls
`pcm_write()`. The app refuses to run when the model, helper hash, root
identity, route state, or direct PCM file descriptor does not match the
verified profile. There is no fallback from Direct ALSA to AudioTrack.

### Pixel 10 Android 17 mmap transport

On `frankel` with Android SDK 37, the existing Direct ALSA checkbox selects
`pcm_mmap_write` with `PCM_MMAP | PCM_NOIRQ` on PCM1. The APK includes an ARM64
executable built from `app/src/main/cpp/pixel10_mmap`; it loads the device's
`/system/lib64/libtinyalsa.so`. The app extracts it into its private files
directory and checks its SHA-256 against the packaged asset before root execution.

This profile accepts 48 kHz integer PCM16/24/32 mono or stereo WAVs. The helper
widens samples to S32_LE exactly and duplicates mono into identical left/right
channels. Stereo channels retain their individual samples. It does not change
the input WAV, sample rate, amplitude, repeats, or delays. The AudioTrack backend
assist carries only stereo silence.

The helper checks that the hardware pointer has passed every source frame,
including source padding and repeat delays, then stops during the added 150 ms
quiet proof tail. Successful mmap logs must include `A2M_ALSA_MMAP_CONFIG`,
`A2M_ALSA_MMAP_RENDERED`, and `A2M_ALSA_MMAP_STOP state=SETUP`; a legacy completion
message alone cannot pass validation. The completion API is reported as
`api=pcm_mmap_write rootVerified=true`. Other device/SDK profiles use their
existing `pcm_write` path.

Successful logs include:

```text
requestedPath=Direct ALSA
A2M_ALSA_ROOT uid=0(root)
A2M_ALSA_ROUTE_ENABLED
A2M_ALSA_PCM_FDS ... /dev/snd/pcmC0D...
A2M_ALSA_PCM_COMPLETE
A2M_ALSA_ROUTE_DISABLED
ALSA stream complete ... api=pcm_write rootVerified=true
playQueue finish stopped=false
```

Direct ALSA bypasses Android's normal waveform-data path and can produce much
higher output than expected. Use a source amplitude appropriate for the
connected speaker and bench setup. This implementation does not bypass the
vendor DSP, ASoC backend, codec, amplifier calibration, or speaker
protection.
