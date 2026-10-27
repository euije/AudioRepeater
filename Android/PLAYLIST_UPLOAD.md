# Saved campaign playlists

Debug playback capabilities export `playlist_settings_version: 1` for hosts that
apply saved campaign inputs without starting playback. The normal launcher reads
`shared_prefs/persisted-playlist.xml` with `autoPlayOnLoad = false`.

The `processing` string uses the existing `debugProcessingJson` schema. Saving
and reopening a playlist now retains effects, output location, usage and content
type. A missing key preserves the previous default for old playlists. The existing
backend flags, `pcm-device`, repeat/delay fields and `record-unprocessed` remain
part of the same preference file. The host sets and verifies STREAM_MUSIC volume
separately.

After restoring a playlist, the app logs its actual backend and processing values
so the host can detect a fallback or an incomplete restoration. No debug audio-path
intent is needed, and opening the uploaded playlist does not autoplay.

`DebugPlaybackContractTest.savedPlaylistRestoresProcessingAndNeverAutoplays`
checks persistence using a separate test preference file; it also checks legacy
playlists that have no processing key.
