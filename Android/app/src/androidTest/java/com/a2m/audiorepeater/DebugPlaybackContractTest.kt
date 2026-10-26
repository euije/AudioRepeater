package com.a2m.audiorepeater

import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DebugPlaybackContractTest {
    @Test fun processingSurvivesJsonAndIntentWithoutChangingValues() {
        val processing = PlaybackProcessing(
            effects = PlaybackEffects(selection = PlaybackEffect.DYNAMICS, inputGainDb = -6f,
                bands = listOf(DynamicsBandSettings(200f, ratio = 3f),
                    DynamicsBandSettings(2000f), DynamicsBandSettings(20000f, enabled = false))),
            location = PlaybackLocation.RECEIVER, usage = 14, contentType = 1)
        val json = debugProcessingJson(processing).toString()
        assertEquals(processing, parseDebugProcessing(json))
        val intent = Intent().putExtra("debugAudioPath", "/data/local/tmp/contract-test.wav")
            .putExtra("debugPlaybackProcessing", json)
        assertEquals(processing, DebugAudioConfig.from(intent, true)?.processing)
        assertNull(DebugAudioConfig.from(intent, false))
    }

    @Test fun badProcessingCannotStartPlayback() {
        val bad = debugProcessingJson(PlaybackProcessing()).apply { put("usage", 999) }
        assertThrows(IllegalArgumentException::class.java) { parseDebugProcessing(bad.toString()) }
        val invalid = PlaybackProcessing(effects = PlaybackEffects(inputGainDb = Float.NaN))
        assertThrows(Exception::class.java) { debugProcessingJson(invalid) }
    }
}
