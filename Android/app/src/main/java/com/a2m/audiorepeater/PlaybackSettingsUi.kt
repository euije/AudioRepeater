package com.a2m.audiorepeater

import android.media.AudioAttributes
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

@Composable
internal fun SettingsDivider(title: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.labelLarge)
        HorizontalDivider(Modifier.weight(1f))
    }
}

@Composable
internal fun PlaybackRadio(label: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.selectable(selected, enabled = enabled, role = Role.RadioButton, onClick = onClick)
            .padding(end = 8.dp).heightIn(min = 40.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        RadioButton(selected, onClick = null, enabled = enabled, modifier = Modifier.size(32.dp))
        Text(label, style = MaterialTheme.typography.labelMedium,
            color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f))
    }
}

@Composable
internal fun PlaybackBackendControls(
    selected: PlaybackBackend, rootAvailable: Boolean, rootChecking: Boolean, initSupported: Boolean,
    enabled: Boolean, onSelect: (PlaybackBackend) -> Unit, onCheckRoot: () -> Unit
) {
    SettingsDivider("재생")
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).selectableGroup()) {
        PlaybackBackend.entries.filter { it != PlaybackBackend.ALSA_INIT || initSupported }.forEach { backend ->
            PlaybackRadio(backend.label, selected == backend,
                enabled && (backend != PlaybackBackend.ALSA_ROOT || rootAvailable)) { onSelect(backend) }
        }
    }
    if (!rootAvailable) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (rootChecking) "루트 권한 확인 중" else "ALSA(root): 앱 루트 권한 없음",
                style = MaterialTheme.typography.labelSmall)
            TextButton(onClick = onCheckRoot, enabled = enabled && !rootChecking,
                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 0.dp), modifier = Modifier.height(28.dp)) {
                Text("다시 확인", style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}

@Composable
internal fun PlaybackProcessingControls(
    value: PlaybackProcessing, onChange: (PlaybackProcessing) -> Unit, enabled: Boolean,
    supportsProcessing: Boolean
) {
    var showEq by remember { mutableStateOf(false) }
    var showDynamics by remember { mutableStateOf(false) }
    var showAttributes by remember { mutableStateOf(false) }
    val active = enabled && supportsProcessing
    SettingsDivider("재생 효과")
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically) {
        listOf(PlaybackEffect.EQUALIZER, PlaybackEffect.DYNAMICS).forEach { effect ->
            Checkbox(
                checked = supportsProcessing && value.effects.selection == effect,
                onCheckedChange = { checked -> onChange(value.copy(effects = value.effects.copy(
                    selection = if (checked) effect else PlaybackEffect.NONE))) },
                enabled = active, modifier = Modifier.size(32.dp)
            )
            Text(effect.label, style = MaterialTheme.typography.labelMedium)
            TextButton(onClick = { if (effect == PlaybackEffect.EQUALIZER) showEq = true else showDynamics = true },
                enabled = active, contentPadding = PaddingValues(horizontal = 6.dp)) { Text("설정") }
        }
    }
    if (!supportsProcessing) {
        Text("재생 효과·위치 설정은 AudioTrack에서 지원합니다.", style = MaterialTheme.typography.labelSmall)
    }
    SettingsDivider("재생 위치")
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).selectableGroup()) {
        val communication = supportsProcessing && value.location != PlaybackLocation.DEFAULT
        PlaybackRadio("MODE_NORMAL", !communication, active) { onChange(value.copy(location = PlaybackLocation.DEFAULT)) }
        PlaybackRadio("MODE_IN_COMMUNICATION", communication, active) {
            if (!communication) onChange(value.copy(location = PlaybackLocation.RECEIVER))
        }
    }
    if (supportsProcessing && value.location != PlaybackLocation.DEFAULT) {
        Row(Modifier.fillMaxWidth().selectableGroup(), verticalAlignment = Alignment.CenterVertically) {
            Text("출력", style = MaterialTheme.typography.labelMedium)
            PlaybackRadio("수화부", value.location == PlaybackLocation.RECEIVER, active) {
                onChange(value.copy(location = PlaybackLocation.RECEIVER))
            }
            PlaybackRadio("스피커", value.location == PlaybackLocation.SPEAKER, active) {
                onChange(value.copy(location = PlaybackLocation.SPEAKER))
            }
        }
    }
    TextButton(onClick = { showAttributes = true }, enabled = active && value.location == PlaybackLocation.DEFAULT,
        contentPadding = PaddingValues(0.dp), modifier = Modifier.height(28.dp)) {
        Text(if (value.location == PlaybackLocation.DEFAULT)
            "Usage: ${usageChoices.firstOrNull { it.second == value.usage }?.first} · ContentType: ${contentChoices.firstOrNull { it.second == value.contentType }?.first}"
            else "USAGE_VOICE_COMMUNICATION · CONTENT_TYPE_SPEECH", style = MaterialTheme.typography.labelSmall)
    }
    if (showEq) EqualizerSettingsDialog(value.effects, { showEq = false }) {
        onChange(value.copy(effects = it)); showEq = false
    }
    if (showDynamics) DynamicsSettingsDialog(value.effects, { showDynamics = false }) {
        onChange(value.copy(effects = it)); showDynamics = false
    }
    if (showAttributes) AttributesDialog(value, { showAttributes = false }) {
        onChange(it); showAttributes = false
    }
}

@Composable
private fun EqualizerSettingsDialog(value: PlaybackEffects, onDismiss: () -> Unit, onApply: (PlaybackEffects) -> Unit) {
    var capabilities by remember { mutableStateOf<EqualizerCapabilities?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var draft by remember { mutableStateOf(value) }
    LaunchedEffect(Unit) {
        val result = withContext(Dispatchers.IO) { runCatching { queryEqualizerCapabilities() } }
        result.onSuccess { caps ->
            capabilities = caps
            val levels = if (draft.eqPreset in caps.presets.indices) caps.presetLevels[draft.eqPreset]
                else draft.eqLevelsMb.takeIf { it.size == caps.centersHz.size } ?: List(caps.centersHz.size) { 0 }
            draft = draft.copy(eqLevelsMb = levels)
        }.onFailure { error = "이 기기에서 EQ를 열 수 없습니다: ${it.message}" }
    }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Equalizer") },
        text = {
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                Text("설정은 다음 재생부터 적용됩니다. 단위: dB", style = MaterialTheme.typography.bodySmall)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                val caps = capabilities
                if (caps == null && error == null) Text("기기 EQ 확인 중…")
                if (caps != null) {
                    ChoiceMenu("프리셋", listOf("사용자 설정" to -1) + caps.presets.mapIndexed { index, name -> name to index }, draft.eqPreset) { preset ->
                        draft = draft.copy(eqPreset = preset, eqLevelsMb = if (preset >= 0) caps.presetLevels[preset] else draft.eqLevelsMb)
                    }
                    caps.centersHz.forEachIndexed { index, hz ->
                        ParameterSlider("$hz Hz", draft.eqLevelsMb[index] / 100f,
                            caps.minimumMb / 100f..maxOf(caps.maximumMb / 100f, caps.minimumMb / 100f + 0.01f)) { level ->
                            val levels = draft.eqLevelsMb.toMutableList()
                            levels[index] = (level * 100).roundToInt()
                            draft = draft.copy(eqPreset = -1, eqLevelsMb = levels)
                        }
                    }
                }
            }
        }, confirmButton = { TextButton(onClick = { onApply(draft) }, enabled = capabilities != null) { Text("적용") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("취소") } })
}

@Composable
private fun DynamicsSettingsDialog(value: PlaybackEffects, onDismiss: () -> Unit, onApply: (PlaybackEffects) -> Unit) {
    var draft by remember { mutableStateOf(value) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Dynamics Processing") },
        text = {
            Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                Text("모든 채널에 적용합니다. 설정은 다음 재생부터 적용됩니다.", style = MaterialTheme.typography.bodySmall)
                ParameterSlider("Input gain (dB)", draft.inputGainDb, -60f..24f) { draft = draft.copy(inputGainDb = it) }
                ParameterSlider("Limiter threshold (dB)", draft.limiterThresholdDb, -60f..0f) { draft = draft.copy(limiterThresholdDb = it) }
                ParameterSlider("Limiter post gain (dB)", draft.limiterPostGainDb, -60f..24f) { draft = draft.copy(limiterPostGainDb = it) }
                draft.bands.forEachIndexed { index, band ->
                    val update: (DynamicsBandSettings) -> Unit = { next ->
                        draft = draft.copy(bands = draft.bands.toMutableList().also { it[index] = next })
                    }
                    HorizontalDivider()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(band.enabled, { update(band.copy(enabled = it)) })
                        Text("Band ${index + 1} · ${band.cutoffHz.roundToInt()} Hz")
                    }
                    ParameterSlider("Threshold (dB)", band.thresholdDb, -60f..0f) { update(band.copy(thresholdDb = it)) }
                    ParameterSlider("Ratio", band.ratio, 1f..20f) { update(band.copy(ratio = it)) }
                    ParameterSlider("Attack (ms)", band.attackMs, 0.1f..100f) { update(band.copy(attackMs = it)) }
                    ParameterSlider("Release (ms)", band.releaseMs, 1f..1000f) { update(band.copy(releaseMs = it)) }
                }
                Text("샘플레이트가 낮으면 밴드 주파수를 Nyquist 주파수 이하로 제한합니다.", style = MaterialTheme.typography.bodySmall)
            }
        }, confirmButton = { TextButton(onClick = { onApply(draft) }) { Text("적용") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("취소") } })
}

@Composable
private fun ParameterSlider(label: String, value: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Text("$label: ${"%.1f".format(value)}", style = MaterialTheme.typography.bodySmall)
    Slider(value.coerceIn(range), onValueChange = onChange, valueRange = range)
}

private val usageChoices = listOf(
    "Media" to AudioAttributes.USAGE_MEDIA, "Voice communication" to AudioAttributes.USAGE_VOICE_COMMUNICATION,
    "Voice signalling" to AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING,
    "Alarm" to AudioAttributes.USAGE_ALARM, "Notification" to AudioAttributes.USAGE_NOTIFICATION,
    "Ringtone" to AudioAttributes.USAGE_NOTIFICATION_RINGTONE, "Sonification" to AudioAttributes.USAGE_ASSISTANCE_SONIFICATION,
    "Accessibility" to AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY, "Navigation" to AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE,
    "Game" to AudioAttributes.USAGE_GAME, "Assistant" to AudioAttributes.USAGE_ASSISTANT
)
private val contentChoices = listOf("Music" to AudioAttributes.CONTENT_TYPE_MUSIC,
    "Speech" to AudioAttributes.CONTENT_TYPE_SPEECH, "Sonification" to AudioAttributes.CONTENT_TYPE_SONIFICATION)

@Composable
private fun AttributesDialog(value: PlaybackProcessing, onDismiss: () -> Unit, onApply: (PlaybackProcessing) -> Unit) {
    var draft by remember { mutableStateOf(value) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("오디오 속성") }, text = {
        Column {
            ChoiceMenu("Usage", usageChoices, draft.usage) { draft = draft.copy(usage = it) }
            ChoiceMenu("ContentType", contentChoices, draft.contentType) { draft = draft.copy(contentType = it) }
        }
    }, confirmButton = { TextButton(onClick = { onApply(draft) }) { Text("적용") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("취소") } })
}

@Composable
private fun ChoiceMenu(label: String, options: List<Pair<String, Int>>, selected: Int, onSelect: (Int) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { expanded = true }) { Text("$label: ${options.firstOrNull { it.second == selected }?.first ?: "사용자 설정"}") }
        DropdownMenu(expanded, onDismissRequest = { expanded = false }, modifier = Modifier.heightIn(max = 320.dp)) {
            options.forEach { (name, key) -> DropdownMenuItem(text = { Text(name) }, onClick = { onSelect(key); expanded = false }) }
        }
    }
}
