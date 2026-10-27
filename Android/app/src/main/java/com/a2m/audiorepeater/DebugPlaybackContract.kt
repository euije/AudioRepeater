package com.a2m.audiorepeater

import android.content.Context
import android.media.AudioManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Debug-only host bridge. Playback uses the same settings and profiles as the app UI. */
internal fun parseDebugProcessing(value: String?): PlaybackProcessing {
    if (value == null) return PlaybackProcessing()
    val json = JSONObject(value)
    val fx = json.getJSONObject("effects")
    val bands = fx.getJSONArray("bands")
    val processing = PlaybackProcessing(
        effects = PlaybackEffects(
            selection = PlaybackEffect.valueOf(fx.getString("selection")),
            eqPreset = fx.getInt("eqPreset"),
            eqLevelsMb = fx.getJSONArray("eqLevelsMb").let { a -> List(a.length()) { a.getInt(it) } },
            inputGainDb = fx.getDouble("inputGainDb").toFloat(),
            limiterThresholdDb = fx.getDouble("limiterThresholdDb").toFloat(),
            limiterPostGainDb = fx.getDouble("limiterPostGainDb").toFloat(),
            bands = List(bands.length()) { i -> bands.getJSONObject(i).let { b ->
                DynamicsBandSettings(b.getDouble("cutoffHz").toFloat(), b.getDouble("thresholdDb").toFloat(),
                    b.getDouble("ratio").toFloat(), b.getDouble("attackMs").toFloat(),
                    b.getDouble("releaseMs").toFloat(), b.getBoolean("enabled"))
            } }
        ),
        location = PlaybackLocation.valueOf(json.getString("location")),
        usage = json.getInt("usage"), contentType = json.getInt("contentType")
    )
    require(processing.usage in listOf(1, 2, 3, 4, 5, 6, 11, 12, 13, 14, 16))
    require(processing.contentType in 1..4)
    processing.effects.validate()
    return processing
}

internal fun debugProcessingJson(value: PlaybackProcessing): JSONObject = JSONObject().apply {
    put("location", value.location.name); put("usage", value.usage); put("contentType", value.contentType)
    put("effects", JSONObject().apply {
        val fx = value.effects
        put("selection", fx.selection.name); put("eqPreset", fx.eqPreset); put("eqLevelsMb", JSONArray(fx.eqLevelsMb))
        put("inputGainDb", fx.inputGainDb); put("limiterThresholdDb", fx.limiterThresholdDb)
        put("limiterPostGainDb", fx.limiterPostGainDb)
        put("bands", JSONArray().apply { fx.bands.forEach { b -> put(JSONObject().apply {
            put("cutoffHz", b.cutoffHz); put("thresholdDb", b.thresholdDb); put("ratio", b.ratio)
            put("attackMs", b.attackMs); put("releaseMs", b.releaseMs); put("enabled", b.enabled)
        }) } })
    })
}

internal fun exportPlaybackCapabilities(context: Context) {
    val result = JSONObject().apply {
        put("contract_version", 1); put("build", Build.DEVICE); put("model", Build.MODEL)
        put("playlist_settings_version", 1)
        put("sdk", Build.VERSION.SDK_INT); put("fingerprint", Build.FINGERPRINT)
        val root = hasRootAccess()
        put("root", root); put("root_shell", if (root) resolveRootShell() else JSONObject.NULL)
        put("init_supported", deviceSupportsInitAlsa())
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        put("volume", audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
        put("voice_volume", audio.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL))
        put("aaudio", debugAaudioCapability())
        val choices = when (Build.DEVICE) {
            "beyond1" -> listOf(1, 0, 2, 101, 102)
            "lavender" -> listOf(13, 0, 1, 4, 17, 39)
            "ASUS_I005_1" -> listOf(9)
            "flame" -> listOf(13)
            else -> listOf(1)
        }
        put("alsa_profiles", JSONArray().apply { choices.forEach { id ->
            runCatching { RootAlsaProfile.current(id) }.onSuccess { p -> put(JSONObject().apply {
                put("id", id); put("label", p.label); put("pcm", p.pcmDevice)
                put("period", p.periodSize); put("periods", p.periodCount); put("api", p.apiLabel)
                put("mixer", p.tinymixPath); put("route_query", p.routeQueryCommand)
                put("route_disable", p.routeDisableCommand); put("helper_path", p.helperPath)
                put("helper_sha256", p.helperSha256)
            }) }
        } })
        put("equalizer", runCatching { queryEqualizerCapabilities() }.fold({ caps -> JSONObject().apply {
            put("centersHz", JSONArray(caps.centersHz)); put("minimumMb", caps.minimumMb)
            put("maximumMb", caps.maximumMb); put("presets", JSONArray(caps.presets))
            put("presetLevels", JSONArray().apply { caps.presetLevels.forEach { put(JSONArray(it)) } })
        } }, { JSONObject().put("error", it.message) }))
        put("default_processing", debugProcessingJson(PlaybackProcessing()))
    }
    val target = File(context.filesDir, "playback-capabilities.json")
    val temporary = File(context.filesDir, "playback-capabilities.tmp")
    temporary.writeText(result.toString(2))
    check(temporary.renameTo(target)) { "Could not publish playback capabilities" }
}
