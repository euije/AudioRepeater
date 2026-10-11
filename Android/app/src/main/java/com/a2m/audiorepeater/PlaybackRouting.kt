package com.a2m.audiorepeater

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import java.io.Closeable

internal fun PlaybackProcessing.audioAttributes(): AudioAttributes = AudioAttributes.Builder()
    .setUsage(if (location != PlaybackLocation.DEFAULT) AudioAttributes.USAGE_VOICE_COMMUNICATION else when (usage) {
        AudioAttributes.USAGE_MEDIA -> AudioAttributes.USAGE_MEDIA
        AudioAttributes.USAGE_VOICE_COMMUNICATION -> AudioAttributes.USAGE_VOICE_COMMUNICATION
        AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING -> AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING
        AudioAttributes.USAGE_ALARM -> AudioAttributes.USAGE_ALARM
        AudioAttributes.USAGE_NOTIFICATION -> AudioAttributes.USAGE_NOTIFICATION
        AudioAttributes.USAGE_NOTIFICATION_RINGTONE -> AudioAttributes.USAGE_NOTIFICATION_RINGTONE
        AudioAttributes.USAGE_ASSISTANCE_SONIFICATION -> AudioAttributes.USAGE_ASSISTANCE_SONIFICATION
        AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY -> AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY
        AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE -> AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE
        AudioAttributes.USAGE_GAME -> AudioAttributes.USAGE_GAME
        AudioAttributes.USAGE_ASSISTANT -> AudioAttributes.USAGE_ASSISTANT
        else -> error("지원하지 않는 Usage입니다: $usage")
    })
    .setContentType(if (location != PlaybackLocation.DEFAULT) AudioAttributes.CONTENT_TYPE_SPEECH else when (contentType) {
        AudioAttributes.CONTENT_TYPE_MUSIC -> AudioAttributes.CONTENT_TYPE_MUSIC
        AudioAttributes.CONTENT_TYPE_SPEECH -> AudioAttributes.CONTENT_TYPE_SPEECH
        AudioAttributes.CONTENT_TYPE_SONIFICATION -> AudioAttributes.CONTENT_TYPE_SONIFICATION
        else -> error("지원하지 않는 ContentType입니다: $contentType")
    })
    .build()

@Suppress("DEPRECATION")
internal class PlaybackRouting(context: Context, private val location: PlaybackLocation) : Closeable {
    private val manager = context.getSystemService(AudioManager::class.java)
    private val previousMode = manager.mode
    private val previousSpeaker = manager.isSpeakerphoneOn
    private val previousDevice = if (Build.VERSION.SDK_INT >= 31) manager.communicationDevice else null
    private val requestedMode = if (location == PlaybackLocation.DEFAULT) AudioManager.MODE_NORMAL
        else AudioManager.MODE_IN_COMMUNICATION
    private var changedMode = false
    private var changedDevice = false
    private val expectedType = when (location) {
        PlaybackLocation.DEFAULT -> null
        PlaybackLocation.RECEIVER -> AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
        PlaybackLocation.SPEAKER -> AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
    }

    fun apply() {
        try {
            manager.mode = requestedMode
            changedMode = true
            if (expectedType != null) {
                if (Build.VERSION.SDK_INT >= 31) {
                    val device = manager.availableCommunicationDevices.firstOrNull { it.type == expectedType }
                        ?: error("선택한 재생 위치를 사용할 수 없습니다: ${location.label}")
                    check(manager.setCommunicationDevice(device)) { "재생 위치 설정을 거부했습니다: ${location.label}" }
                    changedDevice = true
                } else {
                    check(manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type == expectedType }) {
                        "선택한 출력 장치가 없습니다: ${location.label}"
                    }
                    manager.isSpeakerphoneOn = location == PlaybackLocation.SPEAKER
                    changedDevice = true
                }
            }
            Log.i("AudioRepeater", "routing requested=${location.name} mode=${manager.mode}")
        } catch (error: Exception) {
            close()
            throw error
        }
    }

    fun verify(actualDevice: () -> AudioDeviceInfo?, stopped: () -> Boolean): String {
        val deadline = SystemClock.elapsedRealtime() + 1500
        var device = actualDevice()
        while (expectedType != null && !stopped() && SystemClock.elapsedRealtime() < deadline &&
            (device == null || device.type != expectedType)) {
            Thread.sleep(25)
            device = actualDevice()
        }
        if (stopped()) return "중단"
        check(expectedType == null || device?.type == expectedType) {
            "요청한 재생 위치와 실제 출력이 다릅니다: 요청=${location.label}, 실제=${device?.type ?: "확인 불가"}"
        }
        val label = when (device?.type) {
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "수화부"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "스피커"
            null -> "출력 확인 불가"
            else -> device.productName.toString()
        }
        Log.i("AudioRepeater", "routing actual=$label type=${device?.type} mode=${manager.mode}")
        return label
    }

    override fun close() {
        runCatching {
            if (changedDevice) {
                if (Build.VERSION.SDK_INT >= 31) {
                    if (previousDevice != null && manager.availableCommunicationDevices.any { it.id == previousDevice.id }) {
                        manager.setCommunicationDevice(previousDevice)
                    } else {
                        manager.clearCommunicationDevice()
                    }
                } else {
                    manager.isSpeakerphoneOn = previousSpeaker
                }
                changedDevice = false
            }
        }.onFailure { Log.w("AudioRepeater", "Output route cleanup failed", it) }
        runCatching {
            if (changedMode && manager.mode == requestedMode) manager.mode = previousMode
            changedMode = false
        }.onFailure { Log.w("AudioRepeater", "Audio mode cleanup failed", it) }
    }
}
