package com.a2m.audiorepeater

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.audiofx.AudioEffect
import android.media.audiofx.DynamicsProcessing
import android.media.audiofx.Equalizer
import android.util.Log
import java.io.Closeable

internal data class EqualizerCapabilities(
    val centersHz: List<Int>, val minimumMb: Int, val maximumMb: Int,
    val presets: List<String>, val presetLevels: List<List<Int>>
)

internal fun attachMediaPlayerEffect(session: Int, path: String, settings: PlaybackEffects): AttachedPlaybackEffect {
    if (settings.selection != PlaybackEffect.DYNAMICS) {
        return AttachedPlaybackEffect.attach(session, 2, 48000, settings)
    }
    val extractor = MediaExtractor()
    try {
        extractor.setDataSource(path)
        val format = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
            .first { it.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
        return AttachedPlaybackEffect.attach(session, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
            format.getInteger(MediaFormat.KEY_SAMPLE_RATE), settings)
    } finally { extractor.release() }
}

// This silent, unstarted track supplies an app-owned session for querying the device EQ.
internal fun queryEqualizerCapabilities(): EqualizerCapabilities {
    val track = AudioTrack.Builder()
        .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build())
        .setAudioFormat(AudioFormat.Builder().setSampleRate(48000)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
        .setBufferSizeInBytes(maxOf(4096, AudioTrack.getMinBufferSize(48000,
            AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)))
        .setTransferMode(AudioTrack.MODE_STREAM).build()
    try {
        val eq = Equalizer(0, track.audioSessionId)
        try {
            val indices = 0 until eq.numberOfBands.toInt()
            val presetIndices = 0 until eq.numberOfPresets.toInt()
            return EqualizerCapabilities(
                indices.map { eq.getCenterFreq(it.toShort()) / 1000 },
                eq.bandLevelRange[0].toInt(), eq.bandLevelRange[1].toInt(),
                presetIndices.map { eq.getPresetName(it.toShort()) },
                presetIndices.map { preset ->
                    eq.usePreset(preset.toShort())
                    indices.map { eq.getBandLevel(it.toShort()).toInt() }
                }
            )
        } finally { eq.release() }
    } finally { track.release() }
}

internal class AttachedPlaybackEffect private constructor(val effect: AudioEffect?) : Closeable {
    override fun close() {
        runCatching { effect?.release() }.onFailure { Log.w("AudioRepeater", "Effect cleanup failed", it) }
    }

    companion object {
        fun attach(sessionId: Int, channels: Int, sampleRate: Int, settings: PlaybackEffects): AttachedPlaybackEffect {
            settings.validate()
            var effect: AudioEffect? = null
            try {
                when (settings.selection) {
                    PlaybackEffect.NONE -> Unit
                    PlaybackEffect.EQUALIZER -> {
                        val eq = Equalizer(0, sessionId)
                        effect = eq
                        if (settings.eqPreset >= 0) {
                            require(settings.eqPreset < eq.numberOfPresets) { "이 기기에서 지원하지 않는 EQ 프리셋입니다." }
                            eq.usePreset(settings.eqPreset.toShort())
                        } else if (settings.eqLevelsMb.isNotEmpty()) {
                            require(settings.eqLevelsMb.size == eq.numberOfBands.toInt()) { "EQ 밴드 구성이 바뀌었습니다. EQ 설정을 다시 여세요." }
                            settings.eqLevelsMb.forEachIndexed { index, level ->
                                eq.setBandLevel(index.toShort(), level.coerceIn(eq.bandLevelRange[0].toInt(),
                                    eq.bandLevelRange[1].toInt()).toShort())
                            }
                        }
                    }
                    PlaybackEffect.DYNAMICS -> {
                        val config = DynamicsProcessing.Config.Builder(
                            DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, channels,
                            false, 0, true, settings.bands.size, false, 0, true
                        ).build()
                        val dp = DynamicsProcessing(0, sessionId, config)
                        effect = dp
                        for (index in 0 until channels) {
                            val channel = dp.getChannelByChannelIndex(index)
                            channel.inputGain = settings.inputGainDb
                            val mbc = channel.mbc
                            settings.bands.forEachIndexed { bandIndex, value ->
                                val band = mbc.getBand(bandIndex)
                                band.isEnabled = value.enabled
                                // Preserve band order for sources with a low Nyquist frequency.
                                band.cutoffFrequency = minOf(value.cutoffHz,
                                    sampleRate / 2f * (bandIndex + 1) / settings.bands.size)
                                band.threshold = value.thresholdDb
                                band.ratio = value.ratio
                                band.attackTime = value.attackMs
                                band.releaseTime = value.releaseMs
                                mbc.setBand(bandIndex, band)
                            }
                            channel.mbc = mbc
                            val limiter = channel.limiter
                            limiter.isEnabled = true
                            limiter.threshold = settings.limiterThresholdDb
                            limiter.postGain = settings.limiterPostGainDb
                            channel.limiter = limiter
                            dp.setChannelTo(index, channel)
                        }
                    }
                }
                effect?.let {
                    check(it.hasControl()) { "오디오 효과 제어 권한을 얻지 못했습니다." }
                    check(it.setEnabled(true) == AudioEffect.SUCCESS && it.enabled) { "오디오 효과를 켜지 못했습니다." }
                }
                Log.i("AudioRepeater", "effect=${settings.selection} session=$sessionId channels=$channels sampleRate=$sampleRate settings=$settings")
                return AttachedPlaybackEffect(effect)
            } catch (error: Exception) {
                effect?.release()
                throw IllegalStateException("${settings.selection.label} 적용 실패: ${error.message}", error)
            }
        }
    }
}
