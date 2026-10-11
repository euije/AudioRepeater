package com.a2m.audiorepeater

import java.io.Serializable

internal enum class PlaybackBackend(val label: String) {
    ALSA_ROOT("ALSA(root)"), ALSA_INIT("ALSA(init)"), AAUDIO("AAudio"), AUDIO_TRACK("AudioTrack");

    companion object {
        fun fromLegacy(root: Boolean, init: Boolean, aaudio: Boolean): PlaybackBackend = when {
            init -> ALSA_INIT
            root -> ALSA_ROOT
            aaudio -> AAUDIO
            else -> AUDIO_TRACK
        }
    }
}

internal const val PIXEL4_INIT_FINGERPRINT =
    "google/flame/flame:13/TP1A.221005.002.B2/9382335:user/release-keys"

internal fun supportsInitAlsa(device: String, sdk: Int, fingerprint: String, kernel: String): Boolean =
    device == "flame" && sdk == 33 && fingerprint == PIXEL4_INIT_FINGERPRINT &&
        kernel in setOf("4.14.276-g6ef255005cea", "4.14.276-g6ef255005cea-ab9062920")

internal fun availableBackend(
    requested: PlaybackBackend,
    rootAvailable: Boolean,
    initSupported: Boolean
): PlaybackBackend = when {
    requested == PlaybackBackend.ALSA_ROOT && !rootAvailable -> PlaybackBackend.AUDIO_TRACK
    requested == PlaybackBackend.ALSA_INIT && !initSupported -> PlaybackBackend.AUDIO_TRACK
    else -> requested
}

internal enum class PlaybackEffect(val label: String) {
    NONE("Off"), EQUALIZER("Equalizer"), DYNAMICS("Dynamics Processing")
}

internal enum class PlaybackLocation(val label: String) {
    DEFAULT("Default · MODE_NORMAL"),
    RECEIVER("Receiver · MODE_IN_COMMUNICATION"),
    SPEAKER("Speaker · MODE_IN_COMMUNICATION")
}

internal data class DynamicsBandSettings(
    val cutoffHz: Float,
    val thresholdDb: Float = -12f,
    val ratio: Float = 2f,
    val attackMs: Float = 3f,
    val releaseMs: Float = 80f,
    val enabled: Boolean = true
) : Serializable

internal data class PlaybackEffects(
    val selection: PlaybackEffect = PlaybackEffect.NONE,
    val eqPreset: Int = -1,
    val eqLevelsMb: List<Int> = emptyList(),
    val inputGainDb: Float = 0f,
    val limiterThresholdDb: Float = -1f,
    val limiterPostGainDb: Float = 0f,
    val bands: List<DynamicsBandSettings> = listOf(
        DynamicsBandSettings(200f), DynamicsBandSettings(2000f), DynamicsBandSettings(20000f)
    )
) : Serializable {
    fun validate() {
        require(inputGainDb.isFinite() && inputGainDb in -60f..24f)
        require(limiterThresholdDb.isFinite() && limiterThresholdDb in -60f..0f)
        require(limiterPostGainDb.isFinite() && limiterPostGainDb in -60f..24f)
        require(bands.isNotEmpty())
        bands.forEach {
            require(it.cutoffHz.isFinite() && it.cutoffHz > 0)
            require(it.thresholdDb.isFinite() && it.thresholdDb in -60f..0f)
            require(it.ratio.isFinite() && it.ratio in 1f..20f)
            require(it.attackMs.isFinite() && it.attackMs in 0.1f..1000f)
            require(it.releaseMs.isFinite() && it.releaseMs in 1f..5000f)
        }
        require(bands.zipWithNext().all { (a, b) -> a.cutoffHz < b.cutoffHz })
    }
}

internal data class PlaybackProcessing(
    val effects: PlaybackEffects = PlaybackEffects(),
    val location: PlaybackLocation = PlaybackLocation.DEFAULT,
    val usage: Int = 1, // AudioAttributes.USAGE_MEDIA
    val contentType: Int = 2 // AudioAttributes.CONTENT_TYPE_MUSIC
) : Serializable {
    fun forBackend(backend: PlaybackBackend): PlaybackProcessing =
        if (backend == PlaybackBackend.AUDIO_TRACK) this else PlaybackProcessing()

    fun validateFor(backend: PlaybackBackend) {
        effects.validate()
        require(backend == PlaybackBackend.AUDIO_TRACK || this == PlaybackProcessing()) {
            "Playback effects and output selection require AudioTrack."
        }
    }
}
