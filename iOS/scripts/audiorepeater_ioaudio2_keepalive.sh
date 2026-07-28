#!/bin/sh
set -eu

BUNDLE_ID="com.a2m.audiorepeater.ios"
DOCUMENTS="/var/mobile/Documents"
AUDIO_DIRECTORY="$DOCUMENTS/RemoteAudio"
AUDIO_NAME="a2m_c0004_keepalive_1s.wav"
AUDIO_PATH="$AUDIO_DIRECTORY/$AUDIO_NAME"
MANIFEST="$DOCUMENTS/remote-playback.json"
MANIFEST_TEMP="$DOCUMENTS/remote-playback.json.a2m-c0004"
STATUS_LOG="$DOCUMENTS/remote-playback-status.log"
DURATION_SECONDS="${2:-}"

case "$DURATION_SECONDS" in
    ""|*[!0-9.]*|*.*.*)
        echo "A2M_AUDIOREPEATER invalid-duration=$DURATION_SECONDS" >&2
        exit 2
        ;;
esac

if [ ! -f "$AUDIO_PATH" ]; then
    echo "A2M_AUDIOREPEATER missing-audio=$AUDIO_PATH" >&2
    exit 2
fi

WHOLE_SECONDS="${DURATION_SECONDS%%.*}"
if [ -z "$WHOLE_SECONDS" ]; then
    WHOLE_SECONDS=0
fi
REPEAT_COUNT=$((WHOLE_SECONDS + 1))
if [ "$REPEAT_COUNT" -lt 1 ]; then
    REPEAT_COUNT=1
fi
POLL_LIMIT=$(((REPEAT_COUNT + 15) * 10))

prepare_request() {
    rm -f "$MANIFEST" "$MANIFEST_TEMP" "$STATUS_LOG"
    printf '%s\n' \
        '{' \
        '  "files": [' \
        '    {' \
        "      \"fileName\": \"$AUDIO_NAME\"," \
        '      "displayName": "c0004 AudioRepeater ring keepalive",' \
        "      \"repeatCount\": $REPEAT_COUNT" \
        '    }' \
        '  ],' \
        '  "sameFileDelaySeconds": 0.0,' \
        '  "differentFileDelaySeconds": 0.0,' \
        '  "playbackPath": "avAudioEngine",' \
        '  "captureSystemAudio": false' \
        '}' >"$MANIFEST_TEMP"
    chown mobile:mobile "$MANIFEST_TEMP"
    chmod 600 "$MANIFEST_TEMP"
    mv "$MANIFEST_TEMP" "$MANIFEST"
}

PLAYBACK_ATTEMPT=1
while [ "$PLAYBACK_ATTEMPT" -le 2 ]; do
    if [ "$PLAYBACK_ATTEMPT" -gt 1 ]; then
        killall AudioRepeaterIOS 2>/dev/null || true
    fi
    prepare_request
    echo "A2M_AUDIOREPEATER launch bundle_id=$BUNDLE_ID duration=$DURATION_SECONDS repeats=$REPEAT_COUNT attempt=$PLAYBACK_ATTEMPT"
    /var/jb/usr/bin/uiopen --bundleid "$BUNDLE_ID"

    POLL_ATTEMPT=0
    RETRY_PLAYBACK=0
    while [ "$POLL_ATTEMPT" -lt "$POLL_LIMIT" ]; do
        if [ -f "$STATUS_LOG" ]; then
            if grep -Fq "AudioRepeaterIOS playQueue error" "$STATUS_LOG"; then
                cat "$STATUS_LOG"
                if [ "$PLAYBACK_ATTEMPT" -lt 2 ]; then
                    echo "A2M_AUDIOREPEATER retry-after-playback-error"
                    RETRY_PLAYBACK=1
                    break
                fi
                echo "A2M_AUDIOREPEATER playback-error" >&2
                exit 1
            fi
            if grep -Fq "AudioRepeaterIOS playQueue finish stopped=false" "$STATUS_LOG"; then
                grep -Fq "path=avAudioEngine" "$STATUS_LOG"
                grep -Fq "displayIdleTimerDisabled=true" "$STATUS_LOG"
                grep -Fq "AudioRepeaterIOS route outputs=Speaker:" "$STATUS_LOG"
                grep -Fq "AudioRepeaterIOS PCM ready" "$STATUS_LOG"
                grep -Fq "sampleRate=48000.0" "$STATUS_LOG"
                grep -Fq "AudioRepeaterIOS stream scheduled" "$STATUS_LOG"
                cat "$STATUS_LOG"
                echo "A2M_AUDIOREPEATER complete bundle_id=$BUNDLE_ID repeats=$REPEAT_COUNT attempt=$PLAYBACK_ATTEMPT"
                exit 0
            fi
        fi
        POLL_ATTEMPT=$((POLL_ATTEMPT + 1))
        sleep 0.1
    done

    if [ "$RETRY_PLAYBACK" -eq 1 ]; then
        PLAYBACK_ATTEMPT=$((PLAYBACK_ATTEMPT + 1))
        sleep 1
        continue
    fi

    if [ -f "$STATUS_LOG" ]; then
        cat "$STATUS_LOG"
    fi
    echo "A2M_AUDIOREPEATER timeout duration=$DURATION_SECONDS poll_limit=$POLL_LIMIT; keep iPhone 8 unlocked and AudioRepeater visible" >&2
    exit 1
done

exit 1
