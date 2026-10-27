package com.a2m.audiorepeater

import android.content.Intent
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DebugPlaybackContractTest {
    @Test fun savedPlaylistRestoresProcessingAndNeverAutoplays() {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = target.getSharedPreferences("test-campaign-playlist-settings", Context.MODE_PRIVATE)
        val context = object : ContextWrapper(target) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences = prefs
        }
        try {
            prefs.edit().clear().commit()
            val processing = PlaybackProcessing(
                effects = PlaybackEffects(selection = PlaybackEffect.DYNAMICS, inputGainDb = -5f),
                location = PlaybackLocation.SPEAKER, usage = 14, contentType = 1)
            val intent = Intent().putExtra("debugAudioPath", "/data/local/tmp/m1.wav")
                .putExtra("debugPlaybackProcessing", debugProcessingJson(processing).toString())
            val config = DebugAudioConfig.from(intent, true)!!.copy(repeatCount = 2)
            context.savePersistedDebugAudioConfig(config)
            assertEquals(config.copy(autoPlayOnLoad = false), context.loadPersistedDebugAudioConfig())
            prefs.edit().remove("processing").commit()
            assertEquals(PlaybackProcessing(), context.loadPersistedDebugAudioConfig()?.processing)
        } finally {
            prefs.edit().clear().commit()
        }
    }

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
