package com.a2m.audiorepeater

import android.graphics.Bitmap
import android.content.Context
import android.content.ContextWrapper
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.AudioManager
import android.media.audiofx.DynamicsProcessing
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalContext
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.a2m.audiorepeater.ui.theme.AudioRepeaterTheme
import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlaybackSettingsTest {
    @get:Rule val compose = createComposeRule()

    @Test fun unsupportedInitIsHiddenAndUnrootedAlsaIsDisabled() {
        val backend = mutableStateOf(PlaybackBackend.AUDIO_TRACK)
        compose.setContent { AudioRepeaterTheme {
            Column { PlaybackBackendControls(backend.value, false, false, false, true, { backend.value = it }, {}) }
        } }
        compose.onNodeWithText("ALSA(init)").assertDoesNotExist()
        compose.onNodeWithText("ALSA(root)").assertIsNotEnabled()
        compose.onNodeWithText("AudioTrack").assertIsSelected().performClick().assertIsSelected()
        compose.onNodeWithText("AAudio").performClick().assertIsSelected()
        compose.onNodeWithText("AudioTrack").assertIsNotSelected()
        compose.onAllNodes(isSelected()).assertCountEquals(1)
    }

    @Test fun supportedInitAndRootRemainMutuallyExclusive() {
        val backend = mutableStateOf(PlaybackBackend.AUDIO_TRACK)
        compose.setContent { AudioRepeaterTheme {
            Column { PlaybackBackendControls(backend.value, true, false, true, true, { backend.value = it }, {}) }
        } }
        compose.onNodeWithText("ALSA(init)").assertIsEnabled().performClick().assertIsSelected()
        compose.onNodeWithText("ALSA(root)").performClick().assertIsSelected()
        compose.onNodeWithText("ALSA(init)").assertIsNotSelected()
        compose.onAllNodes(isSelected()).assertCountEquals(1)
    }

    @Test fun fullScreenHasOrderedSectionsAndOneScrollableRepeatRow() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val isolatedContext = object : ContextWrapper(instrumentation.targetContext) {
            override fun getFilesDir() = File(super.getCacheDir(), "settings-test-files").apply { mkdirs() }
            override fun getCacheDir() = File(super.getCacheDir(), "settings-test-cache").apply { mkdirs() }
            override fun getSharedPreferences(name: String, mode: Int) = super.getSharedPreferences("settings-test-$name", mode)
            override fun getApplicationContext(): Context = this
        }
        compose.setContent {
            val registryOwner = checkNotNull(LocalActivityResultRegistryOwner.current)
            CompositionLocalProvider(LocalContext provides isolatedContext,
                LocalActivityResultRegistryOwner provides registryOwner) { AudioRepeaterTheme {
            AudioRepeaterApp(DebugAudioConfig(emptyList(), 1, "0", "0", false, false, false,
                false, false, null, false, false))
        } } }
        val playback = compose.onAllNodesWithText("재생")[0].fetchSemanticsNode().boundsInRoot.top
        val effects = compose.onNodeWithText("재생 효과").fetchSemanticsNode().boundsInRoot.top
        val location = compose.onNodeWithText("재생 위치").fetchSemanticsNode().boundsInRoot.top
        val recording = compose.onNodeWithText("녹음").fetchSemanticsNode().boundsInRoot.top
        assertTrue(playback < effects && effects < location && location < recording)
        compose.onNodeWithText("마이크 동시 녹음 (UNPROCESSED)").assertIsDisplayed()
        val repeatY = compose.onNodeWithText("기본 반복").fetchSemanticsNode().boundsInRoot.center.y
        compose.onNodeWithText("파일 간 딜레이(초)").performScrollTo().assertIsDisplayed()
        val delayY = compose.onNodeWithText("파일 간 딜레이(초)").fetchSemanticsNode().boundsInRoot.center.y
        assertEquals(repeatY, delayY, 2f)
        compose.onNodeWithText("기본 반복").performScrollTo()
        val screenshot = instrumentation.uiAutomation.takeScreenshot()
        File(instrumentation.targetContext.getExternalFilesDir(null), "playback-settings-test.png").outputStream().use {
            screenshot.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        screenshot.recycle()
    }

    @Test fun effectsAttachToNewSessionsAndDynamicsCoversBothChannels() {
        val caps = queryEqualizerCapabilities()
        assertTrue(caps.centersHz.isNotEmpty())
        for (channels in listOf(1, 2)) {
            val mask = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
            val track = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
                .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(mask)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                .setBufferSizeInBytes(maxOf(4096, AudioTrack.getMinBufferSize(48000, mask, AudioFormat.ENCODING_PCM_16BIT)))
                .build()
            try {
                AttachedPlaybackEffect.attach(track.audioSessionId, channels, 48000,
                    PlaybackEffects(selection = PlaybackEffect.EQUALIZER, eqLevelsMb = List(caps.centersHz.size) { 0 })).use { }
                AttachedPlaybackEffect.attach(track.audioSessionId, channels, 48000,
                    PlaybackEffects(selection = PlaybackEffect.DYNAMICS, inputGainDb = -6f)).use { attached ->
                    val inspector = attached.effect as DynamicsProcessing
                    for (channel in 0 until channels) {
                        assertEquals(-6f, inspector.getChannelByChannelIndex(channel).inputGain, 0.01f)
                        assertEquals(-1f, inspector.getChannelByChannelIndex(channel).limiter.threshold, 0.01f)
                    }
                }
            } finally { track.release() }
        }
    }

    @Test fun communicationRoutesSilentAudioAndRestoresMode() {
        compose.setContent { AudioRepeaterTheme { androidx.compose.material3.Text("무음 라우팅 검증") } }
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = context.getSystemService(AudioManager::class.java)
        val originalMode = manager.mode
        for (location in listOf(PlaybackLocation.RECEIVER, PlaybackLocation.SPEAKER)) {
            val routing = PlaybackRouting(context, location)
            try {
                routing.apply()
                val track = AudioTrack.Builder().setAudioAttributes(PlaybackProcessing(location = location).audioAttributes())
                    .setAudioFormat(AudioFormat.Builder().setSampleRate(48000)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                    .setBufferSizeInBytes(maxOf(16384, AudioTrack.getMinBufferSize(48000,
                        AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT))).build()
                try {
                    track.play()
                    val silence = ByteArray(16384)
                    assertEquals(silence.size, track.write(silence, 0, silence.size))
                    assertEquals(if (location == PlaybackLocation.RECEIVER) "수화부" else "스피커",
                        routing.verify({ track.routedDevice }, { false }))
                } finally { track.release() }
            } finally { routing.close() }
            assertEquals(originalMode, manager.mode)
        }
    }
}
