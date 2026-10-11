package com.a2m.audiorepeater

import org.junit.Assert.*
import org.junit.Test

class PlaybackOptionsTest {
    @Test fun initRequiresTheVerifiedDeviceBuildAndKernel() {
        assertTrue(supportsInitAlsa("flame", 33, PIXEL4_INIT_FINGERPRINT, "4.14.276-g6ef255005cea"))
        assertTrue(supportsInitAlsa("flame", 33, PIXEL4_INIT_FINGERPRINT, "4.14.276-g6ef255005cea-ab9062920"))
        assertFalse(supportsInitAlsa("flame", 33, PIXEL4_INIT_FINGERPRINT, "4.14.276-g6ef255005cea-custom"))
        assertFalse(supportsInitAlsa("coral", 33, PIXEL4_INIT_FINGERPRINT, "4.14.276-g6ef255005cea"))
        assertFalse(supportsInitAlsa("flame", 34, PIXEL4_INIT_FINGERPRINT, "4.14.276-g6ef255005cea"))
        assertFalse(supportsInitAlsa("flame", 33, PIXEL4_INIT_FINGERPRINT.replace("B2", "B3"), "4.14.276-g6ef255005cea"))
        assertFalse(supportsInitAlsa("flame", 33, PIXEL4_INIT_FINGERPRINT, "4.14.276-custom"))
    }

    @Test fun inaccessiblePersistedBackendsReturnToAudioTrack() {
        assertEquals(PlaybackBackend.AUDIO_TRACK, availableBackend(PlaybackBackend.ALSA_ROOT, false, false))
        assertEquals(PlaybackBackend.AUDIO_TRACK, availableBackend(PlaybackBackend.ALSA_INIT, true, false))
        assertEquals(PlaybackBackend.ALSA_ROOT, availableBackend(PlaybackBackend.ALSA_ROOT, true, false))
        assertEquals(PlaybackBackend.ALSA_INIT, availableBackend(PlaybackBackend.ALSA_INIT, false, true))
        assertEquals(PlaybackBackend.AAUDIO, availableBackend(PlaybackBackend.AAUDIO, false, false))
    }

    @Test fun oldCheckboxValuesAlwaysResolveToOneBackend() {
        for (root in listOf(false, true)) for (init in listOf(false, true)) for (aaudio in listOf(false, true)) {
            val selection = PlaybackBackend.fromLegacy(root, init, aaudio)
            assertEquals(if (init) PlaybackBackend.ALSA_INIT else if (root) PlaybackBackend.ALSA_ROOT
                else if (aaudio) PlaybackBackend.AAUDIO else PlaybackBackend.AUDIO_TRACK, selection)
        }
    }

    @Test fun frameworkProcessingNeverLeaksIntoDirectPlayback() {
        val config = PlaybackProcessing(PlaybackEffects(selection = PlaybackEffect.DYNAMICS), PlaybackLocation.RECEIVER)
        assertEquals(config, config.forBackend(PlaybackBackend.AUDIO_TRACK))
        listOf(PlaybackBackend.ALSA_ROOT, PlaybackBackend.ALSA_INIT, PlaybackBackend.AAUDIO).forEach {
            assertEquals(PlaybackProcessing(), config.forBackend(it))
            assertThrows(IllegalArgumentException::class.java) { config.validateFor(it) }
        }
    }

    @Test fun rejectsInvalidDynamicsParameters() {
        PlaybackEffects().validate()
        assertThrows(IllegalArgumentException::class.java) { PlaybackEffects(inputGainDb = Float.NaN).validate() }
        assertThrows(IllegalArgumentException::class.java) {
            PlaybackEffects(bands = listOf(DynamicsBandSettings(200f, ratio = 0f))).validate()
        }
        assertThrows(IllegalArgumentException::class.java) {
            PlaybackEffects(bands = listOf(DynamicsBandSettings(2000f), DynamicsBandSettings(200f))).validate()
        }
    }
}
