# Direct ALSA playback

AudioRepeater has a `Direct ALSA (root / TinyALSA pcm_write)` checkbox.

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

Supported device profiles:

| Device | PCM | FE-to-BE route |
| --- | --- | --- |
| Pixel 4 (`flame`) | `/dev/snd/pcmC0D13p` | `TERT_TDM_RX_0 Audio Mixer MultiMedia5` |
| ZFlip3 (`b2q`) | `/dev/snd/pcmC0D9p` | `PRI_TDM_RX_0 Audio Mixer MultiMedia5` |

The common helper must be installed at:

```text
/data/local/tmp/audiorepeater_alsa/tinyplay_pcm_write
```

Required SHA-256:

```text
a4c29d738c76e73c32b4ac7940de5a72974128c14f6a44aacdf9e82e2b8cf785
```

The helper is the AOSP Android 13 TinyALSA build whose playback loop calls
`pcm_write()`. The app refuses to run when the model, helper hash, root
identity, route state, or direct PCM file descriptor does not match the
verified profile. There is no fallback from Direct ALSA to AudioTrack.

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
Qualcomm DSP, ASoC backend, codec, amplifier calibration, or speaker
protection.
