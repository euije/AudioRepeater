package com.a2m.audiorepeater

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.OpenableColumns
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.a2m.audiorepeater.ui.theme.AudioRepeaterTheme
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val debugAudioConfig =
            DebugAudioConfig.from(intent) ?: applicationContext.loadPersistedDebugAudioConfig()
        enableEdgeToEdge()
        setContent {
            AudioRepeaterTheme {
                AudioRepeaterApp(debugAudioConfig = debugAudioConfig)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AudioRepeaterApp(debugAudioConfig: DebugAudioConfig? = null) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val items = remember {
        context.clearAudioCache()
        mutableStateListOf<WavAudioItem>()
    }
    var defaultRepeatText by rememberSaveable { mutableStateOf("1") }
    var sameFileDelayText by rememberSaveable { mutableStateOf("0") }
    var differentFileDelayText by rememberSaveable { mutableStateOf("0") }
    var playbackState by remember { mutableStateOf<PlaybackUiState>(PlaybackUiState.Idle) }
    var isImporting by remember { mutableStateOf(false) }
    var useAaudioExclusive by rememberSaveable {
        mutableStateOf(debugAudioConfig?.useAaudioExclusive ?: false)
    }
    var useDirectAlsa by rememberSaveable {
        mutableStateOf(debugAudioConfig?.useDirectAlsa ?: false)
    }
    var playbackPathStatus by remember {
        mutableStateOf(selectedPlaybackPathStatus(useDirectAlsa, useAaudioExclusive))
    }
    val player = remember {
        AudioQueuePlayer(
            context = context.applicationContext,
            onStateChanged = { playbackState = it },
            onPathStatusChanged = { playbackPathStatus = it },
            onError = { message ->
                scope.launch {
                    snackbarHostState.showSnackbar(message)
                }
            }
        )
    }
    val isPlaying = playbackState !is PlaybackUiState.Idle
    val defaultRepeat = defaultRepeatText.toPositiveRepeatCountOrNull()
    val sameFileDelayMillis = sameFileDelayText.toDelayMillisOrNull()
    val differentFileDelayMillis = differentFileDelayText.toDelayMillisOrNull()
    val canPlay = !isPlaying &&
        !isImporting &&
        items.any { it.isPlaybackEnabled } &&
        sameFileDelayMillis != null &&
        differentFileDelayMillis != null &&
        items.filter { it.isPlaybackEnabled }
            .all { it.repeatText.toPositiveRepeatCountOrNull() != null }

    val documentLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult

        val uris = result.data?.selectedDocumentUris().orEmpty()
        if (uris.isEmpty()) return@rememberLauncherForActivityResult

        val knownUris = items.mapTo(mutableSetOf()) { it.uri }
        val newItemRepeatText = (defaultRepeat ?: 1).toString()
        isImporting = true
        scope.launch {
            try {
                val importResult = withContext(Dispatchers.IO) {
                    context.importWavItems(
                        uris = uris,
                        knownUris = knownUris,
                        repeatText = newItemRepeatText
                    )
                }
                items.addAll(importResult.items)

                val message = when {
                    importResult.items.isNotEmpty() && importResult.skippedCount > 0 -> {
                        "${importResult.items.size}개 추가, ${importResult.skippedCount}개 건너뜀"
                    }
                    importResult.items.isNotEmpty() -> "${importResult.items.size}개 추가됨"
                    else -> "추가된 wav 파일이 없습니다"
                }
                snackbarHostState.showSnackbar(message)
            } finally {
                isImporting = false
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            player.release()
            items.forEach { item -> deleteLocalFileIfOwned(item) }
        }
    }

    LaunchedEffect(debugAudioConfig) {
        var config = debugAudioConfig
        var debugFiles = config?.localPaths?.map { path -> File(path) }.orEmpty()
        if (config == null) {
            debugFiles = context.fallbackDebugAudioFiles()
            if (debugFiles.isEmpty()) return@LaunchedEffect
            config = DebugAudioConfig(
                localPaths = debugFiles.map { file -> file.absolutePath },
                repeatCount = 1,
                sameFileDelaySeconds = "0.8",
                differentFileDelaySeconds = "1.0",
                useAaudioExclusive = false,
                useDirectAlsa = false,
                useLowLatencyAudioTrack = false,
                forceStereoRouteAssist = false,
                directAlsaPcmDevice = null,
                autoPlayOnLoad = true
            )
            Log.i(LOG_TAG, "debug fallback files=${debugFiles.size}")
        }
        if (debugFiles.any { file -> !file.exists() }) {
            val fallbackFiles = context.fallbackDebugAudioFiles()
            if (fallbackFiles.isNotEmpty()) {
                debugFiles = fallbackFiles
                val currentConfig = config
                config = DebugAudioConfig(
                    localPaths = debugFiles.map { file -> file.absolutePath },
                    repeatCount = currentConfig?.repeatCount ?: 1,
                    sameFileDelaySeconds = currentConfig?.sameFileDelaySeconds ?: "0.8",
                    differentFileDelaySeconds = currentConfig?.differentFileDelaySeconds ?: "1.0",
                    useAaudioExclusive = currentConfig?.useAaudioExclusive ?: false,
                    useDirectAlsa = currentConfig?.useDirectAlsa ?: false,
                    useLowLatencyAudioTrack = currentConfig?.useLowLatencyAudioTrack ?: false,
                    forceStereoRouteAssist = currentConfig?.forceStereoRouteAssist ?: false,
                    directAlsaPcmDevice = currentConfig?.directAlsaPcmDevice,
                    autoPlayOnLoad = currentConfig?.autoPlayOnLoad ?: true
                )
                Log.i(LOG_TAG, "debug path fallback files=${debugFiles.size}")
            }
        }
        val missingFile = debugFiles.firstOrNull { file -> !file.exists() }
        if (missingFile != null) {
            snackbarHostState.showSnackbar("디버그 오디오 파일이 없습니다: ${missingFile.name}")
            return@LaunchedEffect
        }

        val activeConfig = config ?: return@LaunchedEffect
        Log.i(LOG_TAG, "debug list files=${debugFiles.size}")

        val debugItems = debugFiles.map { file ->
            WavAudioItem(
                uri = "debug://${file.absolutePath}",
                localPath = file.absolutePath,
                displayName = file.name,
                repeatText = activeConfig.repeatCount.toString(),
                isPlaybackEnabled = context.isPersistedPlaybackEnabled(file.absolutePath),
                deleteLocalFileOnRemove = false
            )
        }
        items.clear()
        items.addAll(debugItems)
        defaultRepeatText = activeConfig.repeatCount.toString()
        sameFileDelayText = activeConfig.sameFileDelaySeconds
        differentFileDelayText = activeConfig.differentFileDelaySeconds
        useAaudioExclusive = activeConfig.useAaudioExclusive
        useDirectAlsa = activeConfig.useDirectAlsa
        playbackPathStatus = selectedPlaybackPathStatus(
            activeConfig.useDirectAlsa,
            activeConfig.useAaudioExclusive
        )
        if (activeConfig.autoPlayOnLoad) {
            context.savePersistedDebugAudioConfig(activeConfig)
            player.play(
                items = debugItems.filter { item -> item.isPlaybackEnabled }.map { item ->
                    QueueItem(
                        sourceUri = item.uri,
                        localPath = item.localPath,
                        displayName = item.displayName,
                        repeatCount = activeConfig.repeatCount
                    )
                },
                sameFileDelayMillis = activeConfig.sameFileDelaySeconds.toDelayMillisOrNull() ?: 0L,
                differentFileDelayMillis = activeConfig.differentFileDelaySeconds.toDelayMillisOrNull() ?: 0L,
                useAaudioExclusive = activeConfig.useAaudioExclusive,
                useDirectAlsa = activeConfig.useDirectAlsa,
                useLowLatencyAudioTrack = activeConfig.useLowLatencyAudioTrack,
                forceStereoRouteAssist = activeConfig.forceStereoRouteAssist,
                directAlsaPcmDevice = activeConfig.directAlsaPcmDevice
            )
        } else {
            Log.i(LOG_TAG, "restored persisted debug list files=${debugItems.size} without autoplay")
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(text = "AudioRepeater") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                    titleContentColor = MaterialTheme.colorScheme.onSurface
                )
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(
                    checked = useDirectAlsa,
                    onCheckedChange = { checked ->
                        useDirectAlsa = checked
                        if (checked) {
                            useAaudioExclusive = false
                        }
                        playbackPathStatus = selectedPlaybackPathStatus(
                            checked,
                            useAaudioExclusive
                        )
                    },
                    enabled = !isPlaying
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Direct ALSA (root / TinyALSA pcm_write)",
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Text(
                        text = "Pixel 4 및 ZFlip3용 · root와 사전 배포된 ALSA 도구 필요",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Checkbox(
                    checked = useAaudioExclusive,
                    onCheckedChange = { checked ->
                        useAaudioExclusive = checked
                        playbackPathStatus = selectedPlaybackPathStatus(
                            useDirectAlsa,
                            checked
                        )
                    },
                    enabled = !isPlaying && !useDirectAlsa
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "AAudio EXCLUSIVE (MMAP)",
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Text(
                        text = playbackPathStatus,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                RepeatTextField(
                    value = defaultRepeatText,
                    onValueChange = { defaultRepeatText = sanitizeRepeatInput(it) },
                    label = "기본 반복",
                    modifier = Modifier.weight(1f),
                    enabled = !isPlaying
                )

                FilledTonalButton(
                    onClick = { documentLauncher.launch(createWavPickerIntent()) },
                    enabled = !isPlaying && !isImporting && defaultRepeat != null
                ) {
                    Icon(
                        imageVector = Icons.Default.Add,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(text = if (isImporting) "추가 중" else "여러개 추가")
                }
            }

            FilledTonalButton(
                onClick = {
                    items.indices.forEach { index ->
                        items[index] = items[index].copy(repeatText = defaultRepeatText)
                    }
                },
                modifier = Modifier.fillMaxWidth(),
                enabled = !isPlaying && defaultRepeat != null && items.isNotEmpty()
            ) {
                Icon(
                    imageVector = Icons.Default.DoneAll,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(text = "전체 반복 적용")
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                DelayTextField(
                    value = sameFileDelayText,
                    onValueChange = { sameFileDelayText = sanitizeDelayInput(it) },
                    label = "같은 파일 딜레이(초)",
                    modifier = Modifier.weight(1f),
                    enabled = !isPlaying
                )

                DelayTextField(
                    value = differentFileDelayText,
                    onValueChange = { differentFileDelayText = sanitizeDelayInput(it) },
                    label = "파일 간 딜레이(초)",
                    modifier = Modifier.weight(1f),
                    enabled = !isPlaying
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Button(
                    onClick = {
                        val queue = items.filter { item -> item.isPlaybackEnabled }.mapNotNull { item ->
                            item.repeatText.toPositiveRepeatCountOrNull()?.let { repeatCount ->
                                QueueItem(
                                    sourceUri = item.uri,
                                    localPath = item.localPath,
                                    displayName = item.displayName,
                                    repeatCount = repeatCount
                                )
                            }
                        }
                        player.play(
                            items = queue,
                            sameFileDelayMillis = sameFileDelayMillis ?: 0L,
                            differentFileDelayMillis = differentFileDelayMillis ?: 0L,
                            useAaudioExclusive = useAaudioExclusive,
                            useDirectAlsa = useDirectAlsa,
                            useLowLatencyAudioTrack = false,
                            forceStereoRouteAssist = false,
                            directAlsaPcmDevice = null
                        )
                    },
                    enabled = canPlay
                ) {
                    Icon(
                        imageVector = Icons.Default.PlayArrow,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(text = "재생")
                }

                FilledTonalButton(
                    onClick = { player.stop() },
                    enabled = isPlaying
                ) {
                    Icon(
                        imageVector = Icons.Default.Stop,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(text = "정지")
                }

                PlaybackStatusText(
                    state = playbackState,
                    modifier = Modifier.weight(1f)
                )
            }

            Text(
                text = "목록 (${items.size})",
                style = MaterialTheme.typography.titleMedium
            )

            if (items.isEmpty()) {
                EmptyListSurface(modifier = Modifier.weight(1f))
            } else {
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    itemsIndexed(
                        items = items,
                        key = { _, item -> item.id }
                    ) { index, item ->
                        val currentUri = when (val state = playbackState) {
                            PlaybackUiState.Idle -> null
                            is PlaybackUiState.Playing -> state.currentUri
                            is PlaybackUiState.Waiting -> state.currentUri
                        }
                        val isCurrent = currentUri == item.uri
                        WavItemRow(
                            index = index,
                            item = item,
                            isCurrent = isCurrent,
                            enabled = !isPlaying,
                            onRepeatChange = { newValue ->
                                items[index] = item.copy(repeatText = sanitizeRepeatInput(newValue))
                            },
                            onPlaybackEnabledChange = { isPlaybackEnabled ->
                                items[index] = item.copy(isPlaybackEnabled = isPlaybackEnabled)
                                context.setPersistedPlaybackEnabled(
                                    item.localPath,
                                    isPlaybackEnabled
                                )
                            },
                            onDelete = {
                                val removedItem = items.removeAt(index)
                                deleteLocalFileIfOwned(removedItem)
                            }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun RepeatTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        enabled = enabled,
        label = { Text(text = label) },
        isError = value.toPositiveRepeatCountOrNull() == null,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        singleLine = true
    )
}

@Composable
private fun DelayTextField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        enabled = enabled,
        label = { Text(text = label) },
        isError = value.toDelayMillisOrNull() == null,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
        singleLine = true
    )
}

@Composable
private fun PlaybackStatusText(
    state: PlaybackUiState,
    modifier: Modifier = Modifier
) {
    val text = when (state) {
        PlaybackUiState.Idle -> "대기"
        is PlaybackUiState.Playing -> {
            "${state.currentDisplayName} · ${state.currentRepeat}/${state.totalRepeats}회"
        }
        is PlaybackUiState.Waiting -> {
            "${state.currentDisplayName} · ${state.nextRepeat}/${state.totalRepeats}회 대기"
        }
    }

    Text(
        text = text,
        modifier = modifier,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

@Composable
private fun EmptyListSurface(modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        tonalElevation = 1.dp,
        color = MaterialTheme.colorScheme.surfaceContainer
    ) {
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "wav 파일 없음",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun WavItemRow(
    index: Int,
    item: WavAudioItem,
    isCurrent: Boolean,
    enabled: Boolean,
    onRepeatChange: (String) -> Unit,
    onPlaybackEnabledChange: (Boolean) -> Unit,
    onDelete: () -> Unit
) {
    val colors = if (isCurrent) {
        CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer
        )
    } else {
        CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
            contentColor = MaterialTheme.colorScheme.onSurface
        )
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        colors = colors
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Checkbox(
                checked = item.isPlaybackEnabled,
                onCheckedChange = onPlaybackEnabledChange,
                enabled = enabled
            )

            Icon(
                imageVector = Icons.Default.MusicNote,
                contentDescription = null,
                modifier = Modifier.size(24.dp)
            )

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "${index + 1}. ${item.displayName}",
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodyLarge
                )
            }

            RepeatTextField(
                value = item.repeatText,
                onValueChange = onRepeatChange,
                label = "횟수",
                modifier = Modifier.width(88.dp),
                enabled = enabled && item.isPlaybackEnabled
            )

            IconButton(
                onClick = onDelete,
                enabled = enabled
            ) {
                Icon(
                    imageVector = Icons.Default.Delete,
                    contentDescription = "삭제"
                )
            }
        }
    }
}

private data class WavAudioItem(
    val uri: String,
    val localPath: String,
    val displayName: String,
    val repeatText: String,
    val isPlaybackEnabled: Boolean = true,
    val deleteLocalFileOnRemove: Boolean = true,
    val id: String = UUID.randomUUID().toString()
)

private data class QueueItem(
    val sourceUri: String,
    val localPath: String,
    val displayName: String,
    val repeatCount: Int
)

private data class ImportResult(
    val items: List<WavAudioItem>,
    val skippedCount: Int
)

private data class DebugAudioConfig(
    val localPaths: List<String>,
    val repeatCount: Int,
    val sameFileDelaySeconds: String,
    val differentFileDelaySeconds: String,
    val useAaudioExclusive: Boolean,
    val useDirectAlsa: Boolean,
    val useLowLatencyAudioTrack: Boolean,
    val forceStereoRouteAssist: Boolean,
    val directAlsaPcmDevice: Int?,
    val autoPlayOnLoad: Boolean
) {
    companion object {
        fun from(intent: Intent): DebugAudioConfig? {
            val paths = intent.debugAudioPaths()
                ?: return null
            val repeatCount = intent.getIntExtra(DEBUG_REPEAT_COUNT_EXTRA, 10).coerceAtLeast(1)
            return DebugAudioConfig(
                localPaths = paths,
                repeatCount = repeatCount,
                sameFileDelaySeconds = intent.getStringExtra(DEBUG_SAME_DELAY_EXTRA) ?: "0",
                differentFileDelaySeconds = intent.getStringExtra(DEBUG_DIFFERENT_DELAY_EXTRA) ?: "0",
                useAaudioExclusive = intent.getBooleanExtra(DEBUG_AAUDIO_EXCLUSIVE_EXTRA, false),
                useDirectAlsa = intent.getBooleanExtra(DEBUG_DIRECT_ALSA_EXTRA, false),
                useLowLatencyAudioTrack =
                    intent.getBooleanExtra(DEBUG_LOW_LATENCY_AUDIOTRACK_EXTRA, false),
                forceStereoRouteAssist =
                    intent.getBooleanExtra(DEBUG_FORCE_STEREO_ROUTE_ASSIST_EXTRA, false),
                directAlsaPcmDevice = if (intent.hasExtra(DEBUG_DIRECT_ALSA_PCM_DEVICE_EXTRA)) {
                    intent.getIntExtra(DEBUG_DIRECT_ALSA_PCM_DEVICE_EXTRA, -1)
                        .takeIf { device -> device >= 0 }
                } else {
                    null
                },
                autoPlayOnLoad = true
            )
        }
    }
}

private fun Context.savePersistedDebugAudioConfig(config: DebugAudioConfig) {
    getSharedPreferences(PERSISTED_PLAYLIST_PREFERENCES, Context.MODE_PRIVATE)
        .edit()
        .putString(PERSISTED_PLAYLIST_PATHS, config.localPaths.joinToString("\n"))
        .putInt(PERSISTED_PLAYLIST_REPEAT_COUNT, config.repeatCount)
        .putString(PERSISTED_PLAYLIST_SAME_DELAY, config.sameFileDelaySeconds)
        .putString(PERSISTED_PLAYLIST_DIFFERENT_DELAY, config.differentFileDelaySeconds)
        .putBoolean(PERSISTED_PLAYLIST_AAUDIO, config.useAaudioExclusive)
        .putBoolean(PERSISTED_PLAYLIST_DIRECT_ALSA, config.useDirectAlsa)
        .putBoolean(PERSISTED_PLAYLIST_LOW_LATENCY, config.useLowLatencyAudioTrack)
        .putBoolean(PERSISTED_PLAYLIST_ROUTE_ASSIST, config.forceStereoRouteAssist)
        .putInt(PERSISTED_PLAYLIST_PCM_DEVICE, config.directAlsaPcmDevice ?: -1)
        .apply()
}

private fun Context.loadPersistedDebugAudioConfig(): DebugAudioConfig? {
    val preferences =
        getSharedPreferences(PERSISTED_PLAYLIST_PREFERENCES, Context.MODE_PRIVATE)
    val paths = preferences.getString(PERSISTED_PLAYLIST_PATHS, null)
        ?.lineSequence()
        ?.filter { path -> path.isNotBlank() }
        ?.toList()
        .orEmpty()
    if (paths.isEmpty()) return null

    return DebugAudioConfig(
        localPaths = paths,
        repeatCount = preferences.getInt(PERSISTED_PLAYLIST_REPEAT_COUNT, 1).coerceAtLeast(1),
        sameFileDelaySeconds = preferences.getString(PERSISTED_PLAYLIST_SAME_DELAY, "0.8")
            ?: "0.8",
        differentFileDelaySeconds =
            preferences.getString(PERSISTED_PLAYLIST_DIFFERENT_DELAY, "0") ?: "0",
        useAaudioExclusive = preferences.getBoolean(PERSISTED_PLAYLIST_AAUDIO, false),
        useDirectAlsa = preferences.getBoolean(PERSISTED_PLAYLIST_DIRECT_ALSA, false),
        useLowLatencyAudioTrack =
            preferences.getBoolean(PERSISTED_PLAYLIST_LOW_LATENCY, false),
        forceStereoRouteAssist =
            preferences.getBoolean(PERSISTED_PLAYLIST_ROUTE_ASSIST, false),
        directAlsaPcmDevice = preferences.getInt(PERSISTED_PLAYLIST_PCM_DEVICE, -1)
            .takeIf { device -> device >= 0 },
        autoPlayOnLoad = false
    )
}

private fun Context.isPersistedPlaybackEnabled(localPath: String): Boolean {
    val disabledPaths =
        getSharedPreferences(PERSISTED_PLAYLIST_PREFERENCES, Context.MODE_PRIVATE)
            .getStringSet(PERSISTED_PLAYLIST_DISABLED_PATHS, emptySet())
            .orEmpty()
    return localPath !in disabledPaths
}

private fun Context.setPersistedPlaybackEnabled(localPath: String, enabled: Boolean) {
    val preferences =
        getSharedPreferences(PERSISTED_PLAYLIST_PREFERENCES, Context.MODE_PRIVATE)
    val disabledPaths =
        preferences.getStringSet(PERSISTED_PLAYLIST_DISABLED_PATHS, emptySet())
            .orEmpty()
            .toMutableSet()
    if (enabled) {
        disabledPaths.remove(localPath)
    } else {
        disabledPaths.add(localPath)
    }
    preferences.edit()
        .putStringSet(PERSISTED_PLAYLIST_DISABLED_PATHS, disabledPaths)
        .apply()
}

private fun selectedPlaybackPathStatus(
    useDirectAlsa: Boolean,
    useAaudioExclusive: Boolean
): String {
    return when {
        useDirectAlsa -> "선택: Direct ALSA (root / TinyALSA pcm_write)"
        useAaudioExclusive -> "선택: AAudio EXCLUSIVE"
        else -> "선택: AudioTrack"
    }
}

private fun Context.fallbackDebugAudioFiles(): List<File> {
    val roots = listOf(
        File(filesDir, "debug-audio/example"),
        File(filesDir, "debug-audio")
    )
    for (root in roots) {
        if (!root.isDirectory) continue
        val files = root.walkTopDown()
            .filter { file -> file.isFile && file.extension.equals("wav", ignoreCase = true) }
            .sortedBy { file -> file.name }
            .toList()
        if (files.isNotEmpty()) return files
    }
    return emptyList()
}

private data class WavPcmSpec(
    val sampleRate: Int,
    val channelMask: Int,
    val channelCount: Int,
    val audioFormat: Int,
    val bitsPerSample: Int,
    val encoding: Int,
    val frameSize: Int,
    val averageBytesPerSecond: Int,
    val dataOffset: Long,
    val dataSize: Long
)

private data class WavFormatChunk(
    val audioFormat: Int,
    val channelCount: Int,
    val sampleRate: Int,
    val averageBytesPerSecond: Int,
    val blockAlign: Int,
    val bitsPerSample: Int,
    val channelMask: Int?
)

private sealed interface PlaybackUiState {
    data object Idle : PlaybackUiState

    data class Playing(
        val currentUri: String,
        val currentDisplayName: String,
        val currentRepeat: Int,
        val totalRepeats: Int
    ) : PlaybackUiState

    data class Waiting(
        val currentUri: String,
        val currentDisplayName: String,
        val nextRepeat: Int,
        val totalRepeats: Int
    ) : PlaybackUiState
}

private data class AaudioStreamInfo(
    val sharingMode: Int,
    val performanceMode: Int,
    val sampleRate: Int,
    val channelCount: Int,
    val framesPerBurst: Int,
    val bufferCapacityFrames: Int,
    val bufferSizeFrames: Int
) {
    val sharingModeLabel: String
        get() = when (sharingMode) {
            0 -> "EXCLUSIVE"
            1 -> "SHARED"
            else -> sharingMode.toString()
        }

    val performanceModeLabel: String
        get() = when (performanceMode) {
            10 -> "NONE"
            11 -> "POWER_SAVING"
            12 -> "LOW_LATENCY"
            else -> performanceMode.toString()
        }
}

private class NativeAaudioStream private constructor() {
    @Volatile
    private var nativeHandle = 0L

    lateinit var info: AaudioStreamInfo
        private set

    private fun openInternal(sampleRate: Int, channelCount: Int) {
        nativeHandle = nativeOpen(sampleRate, channelCount)
        try {
            val values = nativeGetInfo(requireHandle())
            check(values.size >= AAUDIO_INFO_VALUE_COUNT) {
                "AAudio stream info is incomplete"
            }
            info = AaudioStreamInfo(
                sharingMode = values[0],
                performanceMode = values[1],
                sampleRate = values[2],
                channelCount = values[3],
                framesPerBurst = values[4],
                bufferCapacityFrames = values[5],
                bufferSizeFrames = values[6]
            )
        } catch (exception: Throwable) {
            close()
            throw exception
        }
    }

    fun start() {
        nativeStart(requireHandle())
    }

    fun write(
        buffer: ByteArray,
        offset: Int,
        byteCount: Int,
        timeoutNanos: Long = AAUDIO_WRITE_TIMEOUT_NANOS
    ): Int {
        return nativeWrite(requireHandle(), buffer, offset, byteCount, timeoutNanos)
    }

    fun framesRead(): Long {
        return nativeGetFramesRead(requireHandle())
    }

    fun xRunCount(): Int {
        return nativeGetXRunCount(requireHandle())
    }

    @Synchronized
    fun requestStop() {
        val handle = nativeHandle
        if (handle != 0L) {
            nativeRequestStop(handle)
        }
    }

    @Synchronized
    fun close() {
        val handle = nativeHandle
        if (handle == 0L) return
        nativeHandle = 0L
        nativeClose(handle)
    }

    private fun requireHandle(): Long {
        return nativeHandle.takeIf { it != 0L }
            ?: error("AAudio stream is closed")
    }

    private external fun nativeOpen(sampleRate: Int, channelCount: Int): Long
    private external fun nativeGetInfo(handle: Long): IntArray
    private external fun nativeStart(handle: Long)
    private external fun nativeWrite(
        handle: Long,
        buffer: ByteArray,
        offset: Int,
        byteCount: Int,
        timeoutNanos: Long
    ): Int
    private external fun nativeGetFramesRead(handle: Long): Long
    private external fun nativeGetXRunCount(handle: Long): Int
    private external fun nativeRequestStop(handle: Long)
    private external fun nativeClose(handle: Long)

    companion object {
        init {
            System.loadLibrary("audiorepeater_native")
        }

        fun open(sampleRate: Int, channelCount: Int): NativeAaudioStream {
            return NativeAaudioStream().apply {
                openInternal(sampleRate, channelCount)
            }
        }

        private const val AAUDIO_INFO_VALUE_COUNT = 7
        private const val AAUDIO_WRITE_TIMEOUT_NANOS = 1_000_000_000L
    }
}

private data class RootAlsaProfile(
    val label: String,
    val expectedDevice: String,
    val card: Int,
    val pcmDevice: Int,
    val pcmNode: String,
    val periodSize: Int,
    val periodCount: Int,
    val tinymixPath: String,
    val routeQueryCommand: String,
    val routeEnableCommand: String,
    val routeDisableCommand: String
) {
    fun playbackCommand(wavPath: String): String {
        val helper = shellQuote(ROOT_ALSA_TINYPLAY_PATH)
        val input = shellQuote(wavPath)
        val expectedHash = shellQuote(ROOT_ALSA_TINYPLAY_SHA256)
        val expectedDeviceValue = shellQuote(expectedDevice)
        val expectedNodeValue = shellQuote(pcmNode)
        return """
            set -u
            helper=$helper
            input=$input
            expected_hash=$expectedHash
            expected_device=$expectedDeviceValue
            expected_node=$expectedNodeValue
            cleanup() {
              $routeDisableCommand >/dev/null 2>&1 || true
              final_route=$($routeQueryCommand 2>&1 || true)
              echo "A2M_ALSA_ROUTE_DISABLED ${'$'}final_route"
            }
            trap cleanup EXIT HUP INT TERM
            actual_device=${'$'}(getprop ro.product.device)
            [ "${'$'}actual_device" = "${'$'}expected_device" ] || {
              echo "A2M_ALSA_DEVICE_MISMATCH actual=${'$'}actual_device expected=${'$'}expected_device"
              exit 20
            }
            [ -x "${'$'}helper" ] || {
              echo "A2M_ALSA_HELPER_MISSING ${'$'}helper"
              exit 21
            }
            actual_hash=${'$'}(sha256sum "${'$'}helper" | cut -d ' ' -f 1)
            [ "${'$'}actual_hash" = "${'$'}expected_hash" ] || {
              echo "A2M_ALSA_HELPER_HASH_MISMATCH actual=${'$'}actual_hash expected=${'$'}expected_hash"
              exit 22
            }
            [ -r "${'$'}input" ] || {
              echo "A2M_ALSA_INPUT_UNREADABLE ${'$'}input"
              exit 23
            }
            echo "A2M_ALSA_ROOT ${'$'}(id)"
            echo "A2M_ALSA_PROFILE $label card=$card device=$pcmDevice node=${'$'}expected_node period=$periodSize x $periodCount"
            $routeEnableCommand
            active_route=${'$'}($routeQueryCommand 2>&1)
            echo "A2M_ALSA_ROUTE_ENABLED ${'$'}active_route"
            case "${'$'}active_route" in
              *On*) ;;
              *) echo "A2M_ALSA_ROUTE_ENABLE_FAILED"; exit 24 ;;
            esac
            "${'$'}helper" "${'$'}input" -D $card -d $pcmDevice -p $periodSize -n $periodCount &
            pcm_pid=${'$'}!
            echo "A2M_ALSA_PCM_PID ${'$'}pcm_pid"
            fd_targets=
            fd_probe=0
            while [ "${'$'}fd_probe" -lt 20 ]; do
              fd_targets=${'$'}(
                for fd in /proc/"${'$'}pcm_pid"/fd/*; do
                  readlink "${'$'}fd" 2>/dev/null || true
                done
              )
              case "${'$'}fd_targets" in
                *"${'$'}expected_node"*) break ;;
              esac
              kill -0 "${'$'}pcm_pid" 2>/dev/null || break
              fd_probe=${'$'}((fd_probe + 1))
              sleep 0.005
            done
            echo "A2M_ALSA_PCM_FDS ${'$'}fd_targets"
            case "${'$'}fd_targets" in
              *"${'$'}expected_node"*) ;;
              *)
                if ! kill -0 "${'$'}pcm_pid" 2>/dev/null; then
                  wait "${'$'}pcm_pid"
                  pcm_rc=${'$'}?
                  [ "${'$'}pcm_rc" -eq 0 ] || {
                    echo "A2M_ALSA_PCM_FAILED exit=${'$'}pcm_rc"
                    exit "${'$'}pcm_rc"
                  }
                  echo "A2M_ALSA_PCM_SHORT_COMPLETE requested_node=${'$'}expected_node"
                  echo "A2M_ALSA_PCM_COMPLETE node=${'$'}expected_node"
                  exit 0
                fi
                echo "A2M_ALSA_PCM_NODE_MISMATCH expected=${'$'}expected_node"
                kill "${'$'}pcm_pid" 2>/dev/null || true
                wait "${'$'}pcm_pid" 2>/dev/null || true
                exit 25
                ;;
            esac
            wait "${'$'}pcm_pid"
            pcm_rc=${'$'}?
            [ "${'$'}pcm_rc" -eq 0 ] || {
              echo "A2M_ALSA_PCM_FAILED exit=${'$'}pcm_rc"
              exit "${'$'}pcm_rc"
            }
            echo "A2M_ALSA_PCM_COMPLETE node=${'$'}expected_node"
        """.trimIndent()
    }

    fun cleanupCommand(): String {
        return "$routeDisableCommand >/dev/null 2>&1 || true"
    }

    companion object {
        fun current(requestedPcmDevice: Int? = null): RootAlsaProfile {
            return when (Build.DEVICE) {
                "flame" -> {
                    require(requestedPcmDevice == null || requestedPcmDevice == 13) {
                        "Pixel 4 direct ALSA only supports PCM13"
                    }
                    RootAlsaProfile(
                        label = "Pixel 4 flame MultiMedia5",
                        expectedDevice = "flame",
                        card = 0,
                        pcmDevice = 13,
                        pcmNode = "/dev/snd/pcmC0D13p",
                        periodSize = 240,
                        periodCount = 2,
                        tinymixPath = "/data/local/tmp/pixel4_alsa/tinymix",
                        routeQueryCommand = "/data/local/tmp/pixel4_alsa/tinymix -D 0 1611",
                        routeEnableCommand = "/data/local/tmp/pixel4_alsa/tinymix -D 0 1611 1 0",
                        routeDisableCommand = "/data/local/tmp/pixel4_alsa/tinymix -D 0 1611 0 0"
                    )
                }
                "b2q" -> when (requestedPcmDevice ?: 9) {
                    0 -> RootAlsaProfile(
                        label = "ZFlip3 b2q MultiMedia1",
                        expectedDevice = "b2q",
                        card = 0,
                        pcmDevice = 0,
                        pcmNode = "/dev/snd/pcmC0D0p",
                        periodSize = 192,
                        periodCount = 4,
                        tinymixPath = "/data/local/tmp/a2m_tinyalsa_postroot/tinymix",
                        routeQueryCommand =
                            "/data/local/tmp/a2m_tinyalsa_postroot/tinymix -D 0 get 2430",
                        routeEnableCommand =
                            "/data/local/tmp/a2m_tinyalsa_postroot/tinymix -D 0 set 2430 1 0",
                        routeDisableCommand =
                            "/data/local/tmp/a2m_tinyalsa_postroot/tinymix -D 0 set 2430 0 0"
                    )
                    9 -> RootAlsaProfile(
                        label = "ZFlip3 b2q MultiMedia5",
                        expectedDevice = "b2q",
                        card = 0,
                        pcmDevice = 9,
                        pcmNode = "/dev/snd/pcmC0D9p",
                        periodSize = 256,
                        periodCount = 4,
                        tinymixPath = "/data/local/tmp/a2m_tinyalsa_postroot/tinymix",
                        routeQueryCommand =
                            "/data/local/tmp/a2m_tinyalsa_postroot/tinymix -D 0 get 2434",
                        routeEnableCommand =
                            "/data/local/tmp/a2m_tinyalsa_postroot/tinymix -D 0 set 2434 1 0",
                        routeDisableCommand =
                            "/data/local/tmp/a2m_tinyalsa_postroot/tinymix -D 0 set 2434 0 0"
                    )
                    else -> error(
                        "ZFlip3 direct ALSA experimental PCM must be 0 or 9: " +
                            requestedPcmDevice
                    )
                }
                else -> error(
                    "Direct ALSA는 검증된 Pixel 4(flame)와 ZFlip3(b2q)에서만 지원합니다: " +
                        "${Build.MODEL}/${Build.DEVICE}"
                )
            }
        }
    }
}

private fun shellQuote(value: String): String {
    return "'" + value.replace("'", "'\"'\"'") + "'"
}

private class AudioQueuePlayer(
    private val context: Context,
    private val onStateChanged: (PlaybackUiState) -> Unit,
    private val onPathStatusChanged: (String) -> Unit,
    private val onError: (String) -> Unit
) {
    private val handler = Handler(Looper.getMainLooper())
    private val playbackScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var playbackJob: Job? = null

    @Volatile
    private var stopped = true

    @Volatile
    private var currentTrack: AudioTrack? = null

    @Volatile
    private var currentMediaPlayer: MediaPlayer? = null

    @Volatile
    private var currentAaudioStream: NativeAaudioStream? = null

    @Volatile
    private var currentRootAlsaProcess: Process? = null

    @Volatile
    private var currentRouteAssistTrack: AudioTrack? = null

    @Volatile
    private var currentRouteAssistThread: Thread? = null

    @Volatile
    private var currentRootAlsaProfile: RootAlsaProfile? = null

    @Volatile
    private var playbackRunId = 0

    fun play(
        items: List<QueueItem>,
        sameFileDelayMillis: Long,
        differentFileDelayMillis: Long,
        useAaudioExclusive: Boolean,
        useDirectAlsa: Boolean,
        useLowLatencyAudioTrack: Boolean,
        forceStereoRouteAssist: Boolean,
        directAlsaPcmDevice: Int?
    ) {
        stop()
        if (items.isEmpty()) return

        val runId = playbackRunId + 1
        playbackRunId = runId
        stopped = false
        playbackJob = playbackScope.launch {
            playQueue(
                runId = runId,
                items = items,
                sameFileDelayMillis = sameFileDelayMillis,
                differentFileDelayMillis = differentFileDelayMillis,
                useAaudioExclusive = useAaudioExclusive,
                useDirectAlsa = useDirectAlsa,
                useLowLatencyAudioTrack = useLowLatencyAudioTrack,
                forceStereoRouteAssist = forceStereoRouteAssist,
                directAlsaPcmDevice = directAlsaPcmDevice
            )
        }
    }

    fun stop() {
        playbackRunId += 1
        stopped = true
        playbackJob?.cancel()
        playbackJob = null
        stopCurrentTrack()
        postState(PlaybackUiState.Idle, runId = null)
    }

    fun release() {
        stop()
        playbackScope.cancel()
    }

    private fun playQueue(
        runId: Int,
        items: List<QueueItem>,
        sameFileDelayMillis: Long,
        differentFileDelayMillis: Long,
        useAaudioExclusive: Boolean,
        useDirectAlsa: Boolean,
        useLowLatencyAudioTrack: Boolean,
        forceStereoRouteAssist: Boolean,
        directAlsaPcmDevice: Int?
    ) {
        val requestedPath = when {
            useDirectAlsa -> "Direct ALSA"
            useAaudioExclusive -> "AAudio EXCLUSIVE"
            useLowLatencyAudioTrack -> "AudioTrack LOW_LATENCY"
            else -> "AudioTrack"
        }
        Log.i(
            LOG_TAG,
            "playQueue start items=${items.size} sameDelay=$sameFileDelayMillis " +
                "diffDelay=$differentFileDelayMillis requestedPath=$requestedPath"
        )
        try {
            items.forEachIndexed { itemIndex, item ->
                if (stopped) return

                val wavSpec = try {
                    parseWavPcmFile(File(item.localPath))
                } catch (exception: Exception) {
                    if (useAaudioExclusive || useDirectAlsa) {
                        throw IllegalArgumentException(
                            "$requestedPath 경로는 PCM WAV 파일만 재생할 수 있습니다: ${item.displayName}",
                            exception
                        )
                    }
                    Log.w(
                        LOG_TAG,
                        "PCM parse failed for ${item.displayName}; falling back to MediaPlayer",
                        exception
                    )
                    null
                }

                if (wavSpec != null) {
                    Log.i(
                        LOG_TAG,
                        "PCM ready file=${item.displayName} sampleRate=${wavSpec.sampleRate} " +
                            "encoding=${wavSpec.encoding} bits=${wavSpec.bitsPerSample} " +
                            "frameSize=${wavSpec.frameSize} dataSize=${wavSpec.dataSize}"
                    )
                }

                if (useDirectAlsa) {
                    val spec = checkNotNull(wavSpec)
                    playPcmRepeatsWithRootAlsa(
                        runId = runId,
                        item = item,
                        wavSpec = spec,
                        sameFileDelayMillis = sameFileDelayMillis,
                        forceStereoRouteAssist = forceStereoRouteAssist,
                        directAlsaPcmDevice = directAlsaPcmDevice
                    )
                } else if (useAaudioExclusive) {
                    val spec = checkNotNull(wavSpec)
                    playPcmRepeatsWithAaudio(
                        runId = runId,
                        item = item,
                        wavSpec = spec,
                        sameFileDelayMillis = sameFileDelayMillis
                    )
                } else {
                    val playedWithPcm = wavSpec?.let { spec ->
                        runCatching {
                            playPcmRepeats(
                                runId = runId,
                                item = item,
                                wavSpec = spec,
                                sameFileDelayMillis = sameFileDelayMillis,
                                useLowLatency = useLowLatencyAudioTrack
                            )
                        }.onFailure { exception ->
                            if (!stopped) {
                                Log.w(
                                    LOG_TAG,
                                    "PCM stream path failed for ${item.displayName}; falling back to MediaPlayer",
                                    exception
                                )
                            }
                        }.isSuccess
                    } ?: false

                    if (!playedWithPcm && !stopped) {
                        playMediaPlayerRepeats(
                            runId = runId,
                            item = item,
                            sameFileDelayMillis = sameFileDelayMillis
                        )
                    }
                }

                if (!stopped && itemIndex < items.lastIndex) {
                    waitBeforeNext(
                        runId = runId,
                        delayMillis = differentFileDelayMillis,
                        nextItem = items[itemIndex + 1],
                        nextRepeat = 1
                    )
                }
            }
        } catch (exception: Throwable) {
            if (!stopped) {
                Log.e(LOG_TAG, "$requestedPath playback failed", exception)
                postError(
                    "$requestedPath 재생 실패: ${exception.message ?: exception.javaClass.simpleName}",
                    runId
                )
            }
        } finally {
            Log.i(LOG_TAG, "playQueue finish stopped=$stopped")
            stopped = true
            postState(PlaybackUiState.Idle, runId = runId)
        }
    }

    private fun playRepeatWithRetries(
        runId: Int,
        item: QueueItem,
        currentRepeat: Int
    ): Boolean {
        var retryCount = 0
        while (!stopped) {
            Log.i(LOG_TAG, "playRepeat start file=${item.displayName} repeat=$currentRepeat/${item.repeatCount}")
            postState(
                PlaybackUiState.Playing(
                    currentUri = item.sourceUri,
                    currentDisplayName = item.displayName,
                    currentRepeat = currentRepeat,
                    totalRepeats = item.repeatCount
                ),
                runId = runId
            )

            val result = runCatching {
                playWithMediaPlayerOnce(item)
            }

            if (result.isSuccess) return true
            if (stopped) return false

            Log.e(LOG_TAG, "playRepeat failed file=${item.displayName} repeat=$currentRepeat", result.exceptionOrNull())

            if (retryCount >= MAX_PLAYBACK_RETRIES) {
                postError("${item.displayName} ${currentRepeat}회차 재생 실패. 다음 파일로 건너뜁니다", runId)
                return false
            }

            retryCount += 1
            postError("${item.displayName} ${currentRepeat}회차 재생 실패. 다시 시도합니다 (${retryCount}/${MAX_PLAYBACK_RETRIES})", runId)
            waitBeforeNext(
                runId = runId,
                delayMillis = RETRY_DELAY_MILLIS,
                nextItem = item,
                nextRepeat = currentRepeat
            )
        }
        return false
    }

    private fun playMediaPlayerRepeats(
        runId: Int,
        item: QueueItem,
        sameFileDelayMillis: Long
    ) {
        var repeat = 0
        while (repeat < item.repeatCount && !stopped) {
            val currentRepeat = repeat + 1
            val played = playRepeatWithRetries(
                runId = runId,
                item = item,
                currentRepeat = currentRepeat
            )
            if (!played) break

            repeat += 1
            if (repeat < item.repeatCount) {
                waitBeforeNext(
                    runId = runId,
                    delayMillis = sameFileDelayMillis,
                    nextItem = item,
                    nextRepeat = repeat + 1
                )
            }
        }
    }

    private fun playPcmRepeats(
        runId: Int,
        item: QueueItem,
        wavSpec: WavPcmSpec,
        sameFileDelayMillis: Long,
        useLowLatency: Boolean
    ) {
        val audioTrack = createPcm16AudioTrack(wavSpec, useLowLatency)
        currentTrack = audioTrack

        try {
            val pathLabel = if (useLowLatency) "AudioTrack LOW_LATENCY" else "AudioTrack"
            postPathStatus("실제: $pathLabel", runId)
            Log.i(
                LOG_TAG,
                "$pathLabel stream start file=${item.displayName} repeats=${item.repeatCount} " +
                    "state=${audioTrack.state} performanceMode=${audioTrack.performanceMode}"
            )
            audioTrack.play()

            var framesWritten = 0L
            repeat(item.repeatCount) { repeatIndex ->
                if (stopped) return@repeat

                val currentRepeat = repeatIndex + 1
                Log.i(LOG_TAG, "PCM repeat queue file=${item.displayName} repeat=$currentRepeat/${item.repeatCount}")
                postState(
                    PlaybackUiState.Playing(
                        currentUri = item.sourceUri,
                        currentDisplayName = item.displayName,
                        currentRepeat = currentRepeat,
                        totalRepeats = item.repeatCount
                    ),
                    runId = runId
                )

                framesWritten += writePcm16AudioData(File(item.localPath), wavSpec) { buffer, byteCount ->
                    writeFully(audioTrack, buffer, byteCount)
                }

                if (!stopped && currentRepeat < item.repeatCount && sameFileDelayMillis > 0L) {
                    postState(
                        PlaybackUiState.Waiting(
                            currentUri = item.sourceUri,
                            currentDisplayName = item.displayName,
                            nextRepeat = currentRepeat + 1,
                            totalRepeats = item.repeatCount
                        ),
                        runId = runId
                    )
                    framesWritten += writePcm16Silence(wavSpec, sameFileDelayMillis) { buffer, byteCount ->
                        writeFully(audioTrack, buffer, byteCount)
                    }
                }
            }

            if (!stopped) {
                waitForAudioTrackDrain(audioTrack, framesWritten, wavSpec.sampleRate)
                Log.i(LOG_TAG, "AudioTrack stream complete file=${item.displayName} framesWritten=$framesWritten")
            }
        } finally {
            if (currentTrack === audioTrack) {
                currentTrack = null
            }
            releaseAudioTrack(audioTrack)
        }
    }

    private fun playPcmRepeatsWithAaudio(
        runId: Int,
        item: QueueItem,
        wavSpec: WavPcmSpec,
        sameFileDelayMillis: Long
    ) {
        val stream = NativeAaudioStream.open(
            sampleRate = wavSpec.sampleRate,
            channelCount = wavSpec.channelCount
        )
        currentAaudioStream = stream
        val info = stream.info

        try {
            postPathStatus(
                "실제: AAudio EXCLUSIVE / LOW_LATENCY / ${info.sampleRate} Hz / burst ${info.framesPerBurst}",
                runId
            )
            Log.i(
                LOG_TAG,
                "AAudio stream opened requestedSharing=EXCLUSIVE actualSharing=${info.sharingModeLabel} " +
                    "performance=${info.performanceModeLabel} sampleRate=${info.sampleRate} " +
                    "channels=${info.channelCount} framesPerBurst=${info.framesPerBurst} " +
                    "bufferCapacity=${info.bufferCapacityFrames} bufferSize=${info.bufferSizeFrames}"
            )

            var streamStarted = false
            fun writeToAaudio(buffer: ByteArray, byteCount: Int) {
                if (!streamStarted) {
                    val primedBytes = stream.write(
                        buffer = buffer,
                        offset = 0,
                        byteCount = byteCount,
                        timeoutNanos = AAUDIO_NON_BLOCKING_TIMEOUT_NANOS
                    )
                    if (primedBytes <= 0) {
                        error("AAudio buffer prefill failed: $primedBytes")
                    }
                    stream.start()
                    streamStarted = true
                    Log.i(LOG_TAG, "AAudio stream started prefilledBytes=$primedBytes")
                    if (primedBytes < byteCount) {
                        writeFully(
                            stream = stream,
                            buffer = buffer,
                            byteCount = byteCount,
                            initialOffset = primedBytes
                        )
                    }
                } else {
                    writeFully(stream, buffer, byteCount)
                }
            }

            var framesWritten = 0L
            repeat(item.repeatCount) { repeatIndex ->
                if (stopped) return@repeat

                val currentRepeat = repeatIndex + 1
                Log.i(
                    LOG_TAG,
                    "AAudio repeat queue file=${item.displayName} repeat=$currentRepeat/${item.repeatCount}"
                )
                postState(
                    PlaybackUiState.Playing(
                        currentUri = item.sourceUri,
                        currentDisplayName = item.displayName,
                        currentRepeat = currentRepeat,
                        totalRepeats = item.repeatCount
                    ),
                    runId = runId
                )

                framesWritten += writePcm16AudioData(File(item.localPath), wavSpec) { buffer, byteCount ->
                    writeToAaudio(buffer, byteCount)
                }

                if (!stopped && currentRepeat < item.repeatCount && sameFileDelayMillis > 0L) {
                    postState(
                        PlaybackUiState.Waiting(
                            currentUri = item.sourceUri,
                            currentDisplayName = item.displayName,
                            nextRepeat = currentRepeat + 1,
                            totalRepeats = item.repeatCount
                        ),
                        runId = runId
                    )
                    framesWritten += writePcm16Silence(wavSpec, sameFileDelayMillis) { buffer, byteCount ->
                        writeToAaudio(buffer, byteCount)
                    }
                }
            }

            if (!stopped) {
                waitForAaudioDrain(stream, framesWritten, wavSpec.sampleRate)
                Log.i(
                    LOG_TAG,
                    "AAudio stream complete file=${item.displayName} framesWritten=$framesWritten " +
                        "xRunCount=${stream.xRunCount()}"
                )
            }
        } finally {
            if (currentAaudioStream === stream) {
                currentAaudioStream = null
            }
            stream.close()
        }
    }

    private fun playPcmRepeatsWithRootAlsa(
        runId: Int,
        item: QueueItem,
        wavSpec: WavPcmSpec,
        sameFileDelayMillis: Long,
        forceStereoRouteAssist: Boolean,
        directAlsaPcmDevice: Int?
    ) {
        val profile = RootAlsaProfile.current(directAlsaPcmDevice)
        val aggregateWav = prepareRootAlsaAggregateWav(
            runId = runId,
            item = item,
            wavSpec = wavSpec,
            sameFileDelayMillis = sameFileDelayMillis
        )
        val routeAssistChannelCount = if (forceStereoRouteAssist) 2 else wavSpec.channelCount
        val routeAssistChannelMask = if (forceStereoRouteAssist) {
            AudioFormat.CHANNEL_OUT_STEREO
        } else {
            wavSpec.channelMask
        }
        val routeAssistTrack = createSilentRouteAssistTrack(
            sampleRate = wavSpec.sampleRate,
            channelMask = routeAssistChannelMask,
            channelCount = routeAssistChannelCount,
            lowLatency = profile.expectedDevice == "b2q" && profile.pcmDevice == 0
        )
        currentRouteAssistTrack = routeAssistTrack
        currentRootAlsaProfile = profile
        var rootOutput = ""

        try {
            postPathStatus("준비: 무음 AudioTrack으로 speaker route 활성화", runId)
            routeAssistTrack.play()
            val routeAssistThread = startSilentRouteAssistWriter(
                audioTrack = routeAssistTrack,
                sampleRate = wavSpec.sampleRate,
                channelCount = routeAssistChannelCount
            )
            currentRouteAssistThread = routeAssistThread
            Log.i(
                LOG_TAG,
                "ALSA route assist started payload=silence-only sampleRate=${wavSpec.sampleRate} " +
                    "channels=$routeAssistChannelCount forcedStereo=$forceStereoRouteAssist " +
                    "lowLatency=${profile.expectedDevice == "b2q" && profile.pcmDevice == 0}"
            )
            Thread.sleep(ROOT_ALSA_ROUTE_STARTUP_MILLIS)
            if (stopped) return

            postPathStatus(
                "실제: Direct ALSA pcm_write / ${profile.pcmNode} / ${wavSpec.sampleRate} Hz",
                runId
            )
            Log.i(
                LOG_TAG,
                "ALSA stream start profile=${profile.label} file=${item.displayName} " +
                    "repeats=${item.repeatCount} aggregate=${aggregateWav.absolutePath}"
            )
            val process = ProcessBuilder(
                "su",
                "-c",
                profile.playbackCommand(aggregateWav.absolutePath)
            )
                .redirectErrorStream(true)
                .start()
            currentRootAlsaProcess = process

            val completed = process.waitFor(ROOT_ALSA_PROCESS_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            if (!completed) {
                process.destroyForcibly()
                process.waitFor(5, TimeUnit.SECONDS)
                error("Direct ALSA root process timeout")
            }
            rootOutput = process.inputStream.bufferedReader().use { reader -> reader.readText() }
            rootOutput.lineSequence()
                .filter { line -> line.isNotBlank() }
                .forEach { line -> Log.i(LOG_TAG, "ALSA root: $line") }

            val exitCode = process.exitValue()
            if (exitCode != 0) {
                error("Direct ALSA root process failed: exit=$exitCode")
            }
            if (
                !rootOutput.contains("A2M_ALSA_ROOT uid=0(root)") ||
                !rootOutput.contains("A2M_ALSA_ROUTE_ENABLED") ||
                !rootOutput.contains("A2M_ALSA_PCM_FDS") ||
                !rootOutput.contains(profile.pcmNode) ||
                !rootOutput.contains("A2M_ALSA_PCM_COMPLETE node=${profile.pcmNode}") ||
                !rootOutput.contains("A2M_ALSA_ROUTE_DISABLED")
            ) {
                error("Direct ALSA runtime proof is incomplete")
            }
            Log.i(
                LOG_TAG,
                "ALSA stream complete file=${item.displayName} node=${profile.pcmNode} " +
                    "api=pcm_write rootVerified=true"
            )
        } finally {
            currentRootAlsaProcess?.let { process ->
                if (process.isAlive) {
                    process.destroyForcibly()
                }
            }
            currentRootAlsaProcess = null

            if (currentRouteAssistTrack === routeAssistTrack) {
                currentRouteAssistTrack = null
            }
            releaseAudioTrack(routeAssistTrack)
            currentRouteAssistThread?.let { thread ->
                thread.interrupt()
                runCatching { thread.join(ROOT_ALSA_ROUTE_THREAD_JOIN_MILLIS) }
            }
            currentRouteAssistThread = null

            val cleanupResult = runRootAlsaCleanup(profile)
            Log.i(
                LOG_TAG,
                "ALSA final cleanup exit=${cleanupResult.first} output=${cleanupResult.second.trim()}"
            )
            currentRootAlsaProfile = null
            if (!aggregateWav.delete()) {
                Log.w(LOG_TAG, "ALSA aggregate cleanup could not delete ${aggregateWav.absolutePath}")
            }
        }
    }

    private fun prepareRootAlsaAggregateWav(
        runId: Int,
        item: QueueItem,
        wavSpec: WavPcmSpec,
        sameFileDelayMillis: Long
    ): File {
        require(
            wavSpec.audioFormat == WAV_FORMAT_PCM &&
                wavSpec.bitsPerSample in ROOT_ALSA_PASSTHROUGH_BITS
        ) {
            "Direct ALSA requires integer PCM 16/24/32-bit WAV for exact-format playback: " +
                "format=${wavSpec.audioFormat} bits=${wavSpec.bitsPerSample}"
        }
        require(wavSpec.dataSize % wavSpec.frameSize == 0L) {
            "WAV data is not frame-aligned"
        }
        val signalFrames = wavSpec.dataSize / wavSpec.frameSize
        val delayFrames = delayMillisToFrameCount(sameFileDelayMillis, wavSpec.sampleRate)
        val proofTailFrames =
            delayMillisToFrameCount(ROOT_ALSA_PROOF_TAIL_MILLIS, wavSpec.sampleRate)
        val totalFrames =
            signalFrames * item.repeatCount +
                delayFrames * (item.repeatCount - 1).coerceAtLeast(0) +
                proofTailFrames
        val dataBytes = totalFrames * wavSpec.frameSize
        require(dataBytes in 1..WAV_UINT32_MAX) {
            "Direct ALSA aggregate WAV is too large: $dataBytes bytes"
        }

        val directory = File(context.cacheDir, ROOT_ALSA_CACHE_DIRECTORY_NAME).apply { mkdirs() }
        val outputFile = File(directory, "${UUID.randomUUID()}.wav")
        try {
            FileOutputStream(outputFile).buffered().use { output ->
                output.writeIntegerPcmWavHeader(
                    sampleRate = wavSpec.sampleRate,
                    channelCount = wavSpec.channelCount,
                    bitsPerSample = wavSpec.bitsPerSample,
                    dataBytes = dataBytes
                )
                var framesWritten = 0L
                repeat(item.repeatCount) { repeatIndex ->
                    if (stopped) return@repeat
                    val currentRepeat = repeatIndex + 1
                    postState(
                        PlaybackUiState.Playing(
                            currentUri = item.sourceUri,
                            currentDisplayName = item.displayName,
                            currentRepeat = currentRepeat,
                            totalRepeats = item.repeatCount
                        ),
                        runId = runId
                    )
                    Log.i(
                        LOG_TAG,
                        "ALSA repeat prepared file=${item.displayName} " +
                            "repeat=$currentRepeat/${item.repeatCount}"
                    )
                    framesWritten += writeExactPcmAudioData(
                        File(item.localPath),
                        wavSpec
                    ) { buffer, byteCount ->
                        output.write(buffer, 0, byteCount)
                    }

                    if (!stopped && currentRepeat < item.repeatCount && sameFileDelayMillis > 0L) {
                        postState(
                            PlaybackUiState.Waiting(
                                currentUri = item.sourceUri,
                                currentDisplayName = item.displayName,
                                nextRepeat = currentRepeat + 1,
                                totalRepeats = item.repeatCount
                            ),
                            runId = runId
                        )
                        framesWritten += writeExactPcmSilence(
                            wavSpec,
                            sameFileDelayMillis
                        ) { buffer, byteCount ->
                            output.write(buffer, 0, byteCount)
                        }
                    }
                }
                framesWritten += writeExactPcmSilence(
                    wavSpec,
                    ROOT_ALSA_PROOF_TAIL_MILLIS
                ) { buffer, byteCount ->
                    output.write(buffer, 0, byteCount)
                }
                check(framesWritten == totalFrames) {
                    "Direct ALSA aggregate frame mismatch: $framesWritten != $totalFrames"
                }
            }
        } catch (exception: Throwable) {
            outputFile.delete()
            throw exception
        }
        Log.i(
            LOG_TAG,
            "ALSA aggregate ready file=${item.displayName} frames=$totalFrames " +
                "bytes=$dataBytes sampleRate=${wavSpec.sampleRate} bits=${wavSpec.bitsPerSample} " +
                "channels=${wavSpec.channelCount} exactSourceEncoding=true"
        )
        return outputFile
    }

    private fun writeExactPcmAudioData(
        file: File,
        wavSpec: WavPcmSpec,
        writeBuffer: (ByteArray, Int) -> Unit
    ): Long {
        val bufferSize = (AUDIO_COPY_BUFFER_SIZE / wavSpec.frameSize) * wavSpec.frameSize
        if (bufferSize <= 0) error("Invalid wav frame size: ${wavSpec.frameSize}")

        val buffer = ByteArray(bufferSize)
        var framesWritten = 0L
        FileInputStream(file).use { input ->
            input.skipFully(wavSpec.dataOffset)
            var remainingBytes = wavSpec.dataSize
            while (remainingBytes > 0L && !stopped) {
                val bytesToRead = minOf(bufferSize.toLong(), remainingBytes).toInt()
                input.readFully(buffer, bytesToRead)
                if (bytesToRead % wavSpec.frameSize != 0) {
                    error("wav data is not aligned to frame size")
                }
                writeBuffer(buffer, bytesToRead)
                framesWritten += bytesToRead / wavSpec.frameSize
                remainingBytes -= bytesToRead.toLong()
            }
        }
        return framesWritten
    }

    private fun writeExactPcmSilence(
        wavSpec: WavPcmSpec,
        delayMillis: Long,
        writeBuffer: (ByteArray, Int) -> Unit
    ): Long {
        val silenceFrameCount = delayMillisToFrameCount(delayMillis, wavSpec.sampleRate)
        if (silenceFrameCount <= 0L) return 0L

        val framesPerBuffer = maxOf(1, AUDIO_COPY_BUFFER_SIZE / wavSpec.frameSize)
        val silenceBuffer = ByteArray(framesPerBuffer * wavSpec.frameSize)
        var remainingFrames = silenceFrameCount
        while (remainingFrames > 0L && !stopped) {
            val framesToWrite = minOf(framesPerBuffer.toLong(), remainingFrames).toInt()
            writeBuffer(silenceBuffer, framesToWrite * wavSpec.frameSize)
            remainingFrames -= framesToWrite.toLong()
        }
        return silenceFrameCount - remainingFrames
    }

    private fun createSilentRouteAssistTrack(
        sampleRate: Int,
        channelMask: Int,
        channelCount: Int,
        lowLatency: Boolean
    ): AudioTrack {
        val minBufferSize = AudioTrack.getMinBufferSize(
            sampleRate,
            channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufferSize <= 0) {
            error("Invalid silent route-assist buffer size: $minBufferSize")
        }
        val frameSize = channelCount * PCM_16BIT_BYTES_PER_SAMPLE
        val bufferSize = if (lowLatency) {
            minBufferSize
        } else {
            maxOf(minBufferSize, sampleRate * frameSize / 10)
        }
        val builder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(channelMask)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
        if (lowLatency) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val audioTrack = builder.build()
        if (audioTrack.state != AudioTrack.STATE_INITIALIZED) {
            audioTrack.release()
            error("Silent route-assist AudioTrack initialization failed")
        }
        return audioTrack
    }

    private fun startSilentRouteAssistWriter(
        audioTrack: AudioTrack,
        sampleRate: Int,
        channelCount: Int
    ): Thread {
        val frameSize = channelCount * PCM_16BIT_BYTES_PER_SAMPLE
        val buffer = ByteArray(maxOf(1, sampleRate / 20) * frameSize)
        return Thread(
            {
                while (!stopped && currentRouteAssistTrack === audioTrack) {
                    val written = audioTrack.write(
                        buffer,
                        0,
                        buffer.size,
                        AudioTrack.WRITE_BLOCKING
                    )
                    if (written < 0) {
                        Log.e(LOG_TAG, "ALSA route-assist write failed: $written")
                        return@Thread
                    }
                }
            },
            "AudioRepeater-ALSA-route-assist"
        ).apply { start() }
    }

    private fun runRootAlsaCleanup(profile: RootAlsaProfile): Pair<Int, String> {
        return runCatching {
            val process = ProcessBuilder("su", "-c", profile.cleanupCommand())
                .redirectErrorStream(true)
                .start()
            val completed = process.waitFor(ROOT_ALSA_CLEANUP_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            if (!completed) {
                process.destroyForcibly()
                return@runCatching -1 to "timeout"
            }
            val output = process.inputStream.bufferedReader().use { reader -> reader.readText() }
            process.exitValue() to output
        }.getOrElse { exception ->
            -1 to (exception.message ?: exception.javaClass.simpleName)
        }
    }

    private fun playWithMediaPlayerOnce(item: QueueItem) {
        Log.i(LOG_TAG, "MediaPlayer fallback start file=${item.displayName}")
        val completionLatch = CountDownLatch(1)
        val failure = AtomicReference<String?>(null)
        val mediaPlayer = MediaPlayer()
        currentMediaPlayer = mediaPlayer

        try {
            mediaPlayer.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            mediaPlayer.setDataSource(item.localPath)
            mediaPlayer.setOnCompletionListener {
                Log.i(LOG_TAG, "MediaPlayer completion file=${item.displayName}")
                completionLatch.countDown()
            }
            mediaPlayer.setOnErrorListener { _, what, extra ->
                Log.e(LOG_TAG, "MediaPlayer error file=${item.displayName} what=$what extra=$extra")
                failure.set("MediaPlayer error what=$what extra=$extra")
                completionLatch.countDown()
                true
            }
            mediaPlayer.prepare()
            val timeoutMillis = mediaPlayer.duration
                .takeIf { it > 0 }
                ?.toLong()
                ?.plus(MEDIA_PLAYER_COMPLETION_GRACE_MILLIS)
                ?: MEDIA_PLAYER_DEFAULT_TIMEOUT_MILLIS

            mediaPlayer.start()
            val deadline = SystemClock.elapsedRealtime() + timeoutMillis
            while (!stopped) {
                val remainingMillis = deadline - SystemClock.elapsedRealtime()
                if (remainingMillis <= 0L) {
                    error("MediaPlayer completion timeout")
                }
                if (completionLatch.await(
                        minOf(remainingMillis, MEDIA_PLAYER_POLL_INTERVAL_MILLIS),
                        TimeUnit.MILLISECONDS
                    )
                ) {
                    break
                }
            }

            failure.get()?.let { error(it) }
            Log.i(LOG_TAG, "MediaPlayer fallback complete file=${item.displayName}")
        } finally {
            if (currentMediaPlayer === mediaPlayer) {
                currentMediaPlayer = null
            }
            releaseMediaPlayer(mediaPlayer)
        }
    }

    private fun waitBeforeNext(
        runId: Int,
        delayMillis: Long,
        nextItem: QueueItem,
        nextRepeat: Int
    ) {
        if (stopped) return
        if (delayMillis <= 0L) return

        postState(
            PlaybackUiState.Waiting(
                currentUri = nextItem.sourceUri,
                currentDisplayName = nextItem.displayName,
                nextRepeat = nextRepeat,
                totalRepeats = nextItem.repeatCount
            ),
            runId = runId
        )

        val endTime = SystemClock.elapsedRealtime() + delayMillis
        while (!stopped) {
            val remainingMillis = endTime - SystemClock.elapsedRealtime()
            if (remainingMillis <= 0L) return
            Thread.sleep(minOf(remainingMillis, DELAY_POLL_INTERVAL_MILLIS))
        }
    }

    private fun writePcm16AudioData(
        file: File,
        wavSpec: WavPcmSpec,
        writeBuffer: (ByteArray, Int) -> Unit
    ): Long {
        val inputBufferSize = (AUDIO_COPY_BUFFER_SIZE / wavSpec.frameSize) * wavSpec.frameSize
        if (inputBufferSize <= 0) error("Invalid wav frame size: ${wavSpec.frameSize}")

        val inputBuffer = ByteArray(inputBufferSize)
        val maxFramesPerChunk = inputBufferSize / wavSpec.frameSize
        val outputBuffer = ByteArray(maxFramesPerChunk * wavSpec.channelCount * PCM_16BIT_BYTES_PER_SAMPLE)
        var framesWritten = 0L

        FileInputStream(file).use { input ->
            input.skipFully(wavSpec.dataOffset)
            var remainingBytes = wavSpec.dataSize

            while (remainingBytes > 0 && !stopped) {
                val bytesToRead = minOf(inputBufferSize.toLong(), remainingBytes).toInt()
                input.readFully(inputBuffer, bytesToRead)
                if (bytesToRead % wavSpec.frameSize != 0) {
                    error("wav data is not aligned to frame size")
                }

                val frameCount = bytesToRead / wavSpec.frameSize
                val outputBytes = convertToPcm16(inputBuffer, frameCount, wavSpec, outputBuffer)
                writeBuffer(outputBuffer, outputBytes)
                framesWritten += frameCount.toLong()
                remainingBytes -= bytesToRead.toLong()
            }
        }

        return framesWritten
    }

    private fun convertToPcm16(
        inputBuffer: ByteArray,
        frameCount: Int,
        wavSpec: WavPcmSpec,
        outputBuffer: ByteArray
    ): Int {
        val inputBytesPerSample = wavSpec.bitsPerSample / 8
        var outputOffset = 0

        for (frameIndex in 0 until frameCount) {
            val frameOffset = frameIndex * wavSpec.frameSize
            for (channelIndex in 0 until wavSpec.channelCount) {
                val sampleOffset = frameOffset + channelIndex * inputBytesPerSample
                val sample16 = when (wavSpec.audioFormat) {
                    WAV_FORMAT_PCM -> readIntegerPcmAs16Bit(inputBuffer, sampleOffset, wavSpec.bitsPerSample)
                    WAV_FORMAT_IEEE_FLOAT -> readFloatPcmAs16Bit(inputBuffer, sampleOffset, wavSpec.bitsPerSample)
                    else -> error("Unsupported wav audio format: ${wavSpec.audioFormat}")
                }

                outputBuffer[outputOffset] = (sample16 and 0xff).toByte()
                outputBuffer[outputOffset + 1] = ((sample16 shr 8) and 0xff).toByte()
                outputOffset += PCM_16BIT_BYTES_PER_SAMPLE
            }
        }

        return outputOffset
    }

    private fun readIntegerPcmAs16Bit(buffer: ByteArray, offset: Int, bitsPerSample: Int): Int {
        return when (bitsPerSample) {
            8 -> {
                val unsignedSample = buffer[offset].toInt() and 0xff
                (unsignedSample - 128) shl 8
            }
            16 -> {
                val low = buffer[offset].toInt() and 0xff
                val high = buffer[offset + 1].toInt()
                ((high shl 8) or low).toShort().toInt()
            }
            24 -> {
                val raw = (buffer[offset].toInt() and 0xff) or
                    ((buffer[offset + 1].toInt() and 0xff) shl 8) or
                    ((buffer[offset + 2].toInt() and 0xff) shl 16)
                val signed = if ((raw and PCM_24BIT_SIGN_BIT) != 0) {
                    raw or PCM_24BIT_SIGN_EXTEND
                } else {
                    raw
                }
                signed shr 8
            }
            32 -> {
                val raw = (buffer[offset].toInt() and 0xff) or
                    ((buffer[offset + 1].toInt() and 0xff) shl 8) or
                    ((buffer[offset + 2].toInt() and 0xff) shl 16) or
                    (buffer[offset + 3].toInt() shl 24)
                raw shr 16
            }
            else -> error("${bitsPerSample}bit PCM wav is not supported")
        }
    }

    private fun readFloatPcmAs16Bit(buffer: ByteArray, offset: Int, bitsPerSample: Int): Int {
        if (bitsPerSample != 32) error("${bitsPerSample}bit float wav is not supported")

        val bits = (buffer[offset].toInt() and 0xff) or
            ((buffer[offset + 1].toInt() and 0xff) shl 8) or
            ((buffer[offset + 2].toInt() and 0xff) shl 16) or
            (buffer[offset + 3].toInt() shl 24)
        val sample = Float.fromBits(bits).coerceIn(-1f, 1f)
        val scaled = if (sample < 0f) sample * 32768f else sample * 32767f
        return scaled.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
    }

    private fun writePcm16Silence(
        wavSpec: WavPcmSpec,
        delayMillis: Long,
        writeBuffer: (ByteArray, Int) -> Unit
    ): Long {
        val silenceFrameCount = delayMillisToFrameCount(delayMillis, wavSpec.sampleRate)
        if (silenceFrameCount <= 0L) return 0L

        val outputFrameSize = wavSpec.channelCount * PCM_16BIT_BYTES_PER_SAMPLE
        val framesPerBuffer = maxOf(1, AUDIO_COPY_BUFFER_SIZE / outputFrameSize)
        val silenceBuffer = ByteArray(framesPerBuffer * outputFrameSize)
        var remainingFrames = silenceFrameCount

        while (remainingFrames > 0L && !stopped) {
            val framesToWrite = minOf(framesPerBuffer.toLong(), remainingFrames).toInt()
            val bytesToWrite = framesToWrite * outputFrameSize
            writeBuffer(silenceBuffer, bytesToWrite)
            remainingFrames -= framesToWrite.toLong()
        }

        return silenceFrameCount - remainingFrames
    }

    private fun writeFully(audioTrack: AudioTrack, buffer: ByteArray, byteCount: Int) {
        var offset = 0
        while (offset < byteCount && !stopped) {
            val written = audioTrack.write(
                buffer,
                offset,
                byteCount - offset,
                AudioTrack.WRITE_BLOCKING
            )
            if (written < 0) error("AudioTrack write failed: $written")
            offset += written
        }
    }

    private fun writeFully(
        stream: NativeAaudioStream,
        buffer: ByteArray,
        byteCount: Int,
        initialOffset: Int = 0
    ) {
        var offset = initialOffset
        while (offset < byteCount && !stopped) {
            val written = stream.write(buffer, offset, byteCount - offset)
            if (written <= 0) error("AAudio write made no progress: $written")
            offset += written
        }
    }

    private fun delayMillisToFrameCount(delayMillis: Long, sampleRate: Int): Long {
        return (delayMillis * sampleRate) / MILLIS_PER_SECOND
    }

    private fun waitForAudioTrackDrain(audioTrack: AudioTrack, framesWritten: Long, sampleRate: Int) {
        val timeoutMillis = ((framesWritten * MILLIS_PER_SECOND) / sampleRate) + AUDIO_DRAIN_TIMEOUT_GRACE_MILLIS
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        while (!stopped) {
            val playedFrames = audioTrack.playbackHeadPosition.toLong() and 0xffffffffL
            if (playedFrames >= framesWritten) return
            if (SystemClock.elapsedRealtime() >= deadline) {
                Log.w(
                    LOG_TAG,
                    "AudioTrack drain timeout playedFrames=$playedFrames framesWritten=$framesWritten"
                )
                return
            }
            Thread.sleep(AUDIO_DRAIN_POLL_INTERVAL_MILLIS)
        }
    }

    private fun waitForAaudioDrain(
        stream: NativeAaudioStream,
        framesWritten: Long,
        sampleRate: Int
    ) {
        val timeoutMillis =
            ((framesWritten * MILLIS_PER_SECOND) / sampleRate) + AUDIO_DRAIN_TIMEOUT_GRACE_MILLIS
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        while (!stopped) {
            val framesRead = stream.framesRead()
            if (framesRead >= framesWritten) return
            if (SystemClock.elapsedRealtime() >= deadline) {
                Log.w(
                    LOG_TAG,
                    "AAudio drain timeout framesRead=$framesRead framesWritten=$framesWritten"
                )
                return
            }
            Thread.sleep(AUDIO_DRAIN_POLL_INTERVAL_MILLIS)
        }
    }

    private fun createPcm16AudioTrack(
        wavSpec: WavPcmSpec,
        useLowLatency: Boolean = false
    ): AudioTrack {
        val minBufferSize = AudioTrack.getMinBufferSize(
            wavSpec.sampleRate,
            wavSpec.channelMask,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (minBufferSize <= 0) {
            error("Invalid AudioTrack buffer size: $minBufferSize")
        }

        val pcm16BytesPerSecond = wavSpec.sampleRate * wavSpec.channelCount * PCM_16BIT_BYTES_PER_SAMPLE
        val bufferSize = if (useLowLatency) {
            minBufferSize
        } else {
            maxOf(minBufferSize, pcm16BytesPerSecond / 10)
        }
        val builder = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(wavSpec.sampleRate)
                    .setChannelMask(wavSpec.channelMask)
                    .build()
            )
            .setBufferSizeInBytes(bufferSize)
            .setTransferMode(AudioTrack.MODE_STREAM)
        if (useLowLatency) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }
        val audioTrack = builder.build()

        if (audioTrack.state != AudioTrack.STATE_INITIALIZED) {
            audioTrack.release()
            error("AudioTrack 초기화 실패")
        }
        Log.i(
            LOG_TAG,
            "AudioTrack created sampleRate=${wavSpec.sampleRate} channelMask=${wavSpec.channelMask} " +
                "encoding=${AudioFormat.ENCODING_PCM_16BIT} bufferSize=$bufferSize " +
                "requestedLowLatency=$useLowLatency actualPerformanceMode=${audioTrack.performanceMode}"
        )
        return audioTrack
    }

    private fun stopCurrentTrack() {
        currentRootAlsaProcess?.let { process ->
            runCatching { process.destroyForcibly() }
            currentRootAlsaProcess = null
        }
        currentRouteAssistTrack?.let { track ->
            releaseAudioTrack(track)
            currentRouteAssistTrack = null
        }
        currentRouteAssistThread?.let { thread ->
            thread.interrupt()
            currentRouteAssistThread = null
        }
        currentRootAlsaProfile?.let { profile ->
            currentRootAlsaProfile = null
            Thread(
                {
                    val result = runRootAlsaCleanup(profile)
                    Log.i(
                        LOG_TAG,
                        "ALSA stop cleanup exit=${result.first} output=${result.second.trim()}"
                    )
                },
                "AudioRepeater-ALSA-cleanup"
            ).start()
        }
        currentAaudioStream?.let { stream ->
            runCatching { stream.requestStop() }
            currentAaudioStream = null
        }
        currentTrack?.let { track ->
            releaseAudioTrack(track)
            currentTrack = null
        }
        currentMediaPlayer?.let { mediaPlayer ->
            releaseMediaPlayer(mediaPlayer)
            currentMediaPlayer = null
        }
    }

    private fun releaseAudioTrack(audioTrack: AudioTrack) {
        runCatching { audioTrack.pause() }
        runCatching { audioTrack.flush() }
        runCatching { audioTrack.release() }
    }

    private fun releaseMediaPlayer(mediaPlayer: MediaPlayer) {
        runCatching {
            if (mediaPlayer.isPlaying) {
                mediaPlayer.stop()
            }
        }
        runCatching { mediaPlayer.release() }
    }

    private fun postState(state: PlaybackUiState, runId: Int?) {
        handler.post {
            if (runId == null || runId == playbackRunId) {
                onStateChanged(state)
            }
        }
    }

    private fun postPathStatus(status: String, runId: Int) {
        handler.post {
            if (runId == playbackRunId) {
                onPathStatusChanged(status)
            }
        }
    }

    private fun postError(message: String, runId: Int) {
        Log.e(LOG_TAG, message)
        handler.post {
            if (runId == playbackRunId) {
                onError(message)
            }
        }
    }
}

private fun parseWavPcmFile(file: File): WavPcmSpec {
    RandomAccessFile(file, "r").use { input ->
        if (input.readFourCc() != "RIFF") error("RIFF header가 없습니다")
        input.readUnsignedIntLe()
        if (input.readFourCc() != "WAVE") error("WAVE header가 없습니다")

        var formatChunk: WavFormatChunk? = null
        var dataOffset: Long? = null
        var dataSize: Long? = null

        while (input.filePointer + WAV_CHUNK_HEADER_SIZE <= input.length()) {
            val chunkId = input.readFourCc()
            val chunkSize = input.readUnsignedIntLe()
            val chunkDataOffset = input.filePointer

            when (chunkId) {
                "fmt " -> {
                    formatChunk = input.readWavFormatChunk(chunkSize)
                }
                "data" -> {
                    dataOffset = chunkDataOffset
                    dataSize = chunkSize
                }
            }

            val paddedChunkSize = chunkSize + (chunkSize % 2L)
            input.seek((chunkDataOffset + paddedChunkSize).coerceAtMost(input.length()))
        }

        val resolvedFormatChunk = formatChunk ?: error("fmt chunk가 없습니다")
        val resolvedDataOffset = dataOffset ?: error("data chunk가 없습니다")
        val resolvedDataSize = dataSize ?: error("data chunk가 없습니다")

        if (resolvedFormatChunk.channelCount !in 1..2) {
            error("${resolvedFormatChunk.channelCount}채널 wav는 지원하지 않습니다")
        }
        if (resolvedFormatChunk.bitsPerSample % 8 != 0) {
            error("${resolvedFormatChunk.bitsPerSample}bit wav는 지원하지 않습니다")
        }

        val expectedFrameSize = resolvedFormatChunk.channelCount * (resolvedFormatChunk.bitsPerSample / 8)
        if (resolvedFormatChunk.blockAlign != expectedFrameSize) {
            error("wav block align이 맞지 않습니다")
        }

        val encoding = when {
            resolvedFormatChunk.audioFormat == WAV_FORMAT_PCM && resolvedFormatChunk.bitsPerSample == 8 -> {
                AudioFormat.ENCODING_PCM_8BIT
            }
            resolvedFormatChunk.audioFormat == WAV_FORMAT_PCM && resolvedFormatChunk.bitsPerSample == 16 -> {
                AudioFormat.ENCODING_PCM_16BIT
            }
            resolvedFormatChunk.audioFormat == WAV_FORMAT_PCM && resolvedFormatChunk.bitsPerSample == 24 -> {
                AudioFormat.ENCODING_PCM_24BIT_PACKED
            }
            resolvedFormatChunk.audioFormat == WAV_FORMAT_PCM && resolvedFormatChunk.bitsPerSample == 32 -> {
                AudioFormat.ENCODING_PCM_32BIT
            }
            resolvedFormatChunk.audioFormat == WAV_FORMAT_IEEE_FLOAT && resolvedFormatChunk.bitsPerSample == 32 -> {
                AudioFormat.ENCODING_PCM_FLOAT
            }
            else -> error("PCM 8/16/24/32bit 또는 float 32bit wav만 지원합니다")
        }

        return WavPcmSpec(
            sampleRate = resolvedFormatChunk.sampleRate,
            channelMask = resolvedFormatChunk.toAudioTrackChannelMask(),
            channelCount = resolvedFormatChunk.channelCount,
            audioFormat = resolvedFormatChunk.audioFormat,
            bitsPerSample = resolvedFormatChunk.bitsPerSample,
            encoding = encoding,
            frameSize = expectedFrameSize,
            averageBytesPerSecond = resolvedFormatChunk.averageBytesPerSecond,
            dataOffset = resolvedDataOffset,
            dataSize = resolvedDataSize
        )
    }
}

private fun RandomAccessFile.readFourCc(): String {
    val bytes = ByteArray(4)
    readFully(bytes)
    return String(bytes, StandardCharsets.US_ASCII)
}

private fun RandomAccessFile.readWavFormatChunk(chunkSize: Long): WavFormatChunk {
    if (chunkSize < WAV_MIN_FMT_CHUNK_SIZE) error("fmt chunk가 너무 짧습니다")

    val baseAudioFormat = readUnsignedShortLe()
    val channelCount = readUnsignedShortLe()
    val sampleRate = readUnsignedIntLe().toInt()
    val averageBytesPerSecond = readUnsignedIntLe().toInt()
    val blockAlign = readUnsignedShortLe()
    val bitsPerSample = readUnsignedShortLe()

    if (baseAudioFormat != WAV_FORMAT_EXTENSIBLE) {
        return WavFormatChunk(
            audioFormat = baseAudioFormat,
            channelCount = channelCount,
            sampleRate = sampleRate,
            averageBytesPerSecond = averageBytesPerSecond,
            blockAlign = blockAlign,
            bitsPerSample = bitsPerSample,
            channelMask = null
        )
    }

    if (chunkSize < WAV_EXTENSIBLE_FMT_CHUNK_SIZE) {
        error("확장 wav fmt chunk가 너무 짧습니다")
    }

    val extensionSize = readUnsignedShortLe()
    if (extensionSize < WAV_EXTENSIBLE_MIN_EXTENSION_SIZE) {
        error("확장 wav fmt 정보가 부족합니다")
    }

    readUnsignedShortLe()
    val channelMask = readUnsignedIntLe().toInt()
    val subFormat = readWavSubFormat()

    return WavFormatChunk(
        audioFormat = subFormat,
        channelCount = channelCount,
        sampleRate = sampleRate,
        averageBytesPerSecond = averageBytesPerSecond,
        blockAlign = blockAlign,
        bitsPerSample = bitsPerSample,
        channelMask = channelMask
    )
}

private fun RandomAccessFile.readWavSubFormat(): Int {
    val first = readUnsignedShortLe()
    val guidTail = ByteArray(WAV_SUBFORMAT_GUID_TAIL.size)
    readFully(guidTail)
    if (!guidTail.contentEquals(WAV_SUBFORMAT_GUID_TAIL)) {
        error("지원되지 않는 wav sub format입니다")
    }
    return first
}

private fun WavFormatChunk.toAudioTrackChannelMask(): Int {
    return when (channelCount) {
        1 -> AudioFormat.CHANNEL_OUT_MONO
        2 -> {
            when (channelMask) {
                null, 0, WAV_CHANNEL_MASK_STEREO -> AudioFormat.CHANNEL_OUT_STEREO
                WAV_CHANNEL_MASK_MONO -> AudioFormat.CHANNEL_OUT_MONO
                else -> AudioFormat.CHANNEL_OUT_STEREO
            }
        }
        else -> error("${channelCount}채널 wav는 지원하지 않습니다")
    }
}

private fun RandomAccessFile.readUnsignedShortLe(): Int {
    val first = read()
    val second = read()
    if (first < 0 || second < 0) throw EOFException()
    return first or (second shl 8)
}

private fun RandomAccessFile.readUnsignedIntLe(): Long {
    val first = read()
    val second = read()
    val third = read()
    val fourth = read()
    if (first < 0 || second < 0 || third < 0 || fourth < 0) throw EOFException()
    return (first.toLong() or
        (second.toLong() shl 8) or
        (third.toLong() shl 16) or
        (fourth.toLong() shl 24)) and 0xffffffffL
}

private fun FileInputStream.skipFully(byteCount: Long) {
    var remaining = byteCount
    while (remaining > 0) {
        val skipped = skip(remaining)
        if (skipped > 0) {
            remaining -= skipped
        } else if (read() >= 0) {
            remaining -= 1
        } else {
            throw EOFException()
        }
    }
}

private fun FileInputStream.readFully(buffer: ByteArray, byteCount: Int) {
    var offset = 0
    while (offset < byteCount) {
        val bytesRead = read(buffer, offset, byteCount - offset)
        if (bytesRead < 0) throw EOFException("Unexpected end of wav data")
        offset += bytesRead
    }
}

private fun OutputStream.writePcm16WavHeader(
    sampleRate: Int,
    channelCount: Int,
    dataBytes: Long
) {
    val blockAlign = channelCount * PCM_16BIT_BYTES_PER_SAMPLE
    val byteRate = sampleRate * blockAlign
    write("RIFF".toByteArray(StandardCharsets.US_ASCII))
    writeUnsignedIntLe(36L + dataBytes)
    write("WAVE".toByteArray(StandardCharsets.US_ASCII))
    write("fmt ".toByteArray(StandardCharsets.US_ASCII))
    writeUnsignedIntLe(16)
    writeUnsignedShortLe(WAV_FORMAT_PCM)
    writeUnsignedShortLe(channelCount)
    writeUnsignedIntLe(sampleRate.toLong())
    writeUnsignedIntLe(byteRate.toLong())
    writeUnsignedShortLe(blockAlign)
    writeUnsignedShortLe(16)
    write("data".toByteArray(StandardCharsets.US_ASCII))
    writeUnsignedIntLe(dataBytes)
}

private fun OutputStream.writeIntegerPcmWavHeader(
    sampleRate: Int,
    channelCount: Int,
    bitsPerSample: Int,
    dataBytes: Long
) {
    require(bitsPerSample in ROOT_ALSA_PASSTHROUGH_BITS)
    val bytesPerSample = bitsPerSample / 8
    val blockAlign = channelCount * bytesPerSample
    val byteRate = sampleRate * blockAlign
    write("RIFF".toByteArray(StandardCharsets.US_ASCII))
    writeUnsignedIntLe(36L + dataBytes)
    write("WAVE".toByteArray(StandardCharsets.US_ASCII))
    write("fmt ".toByteArray(StandardCharsets.US_ASCII))
    writeUnsignedIntLe(16)
    writeUnsignedShortLe(WAV_FORMAT_PCM)
    writeUnsignedShortLe(channelCount)
    writeUnsignedIntLe(sampleRate.toLong())
    writeUnsignedIntLe(byteRate.toLong())
    writeUnsignedShortLe(blockAlign)
    writeUnsignedShortLe(bitsPerSample)
    write("data".toByteArray(StandardCharsets.US_ASCII))
    writeUnsignedIntLe(dataBytes)
}

private fun OutputStream.writeUnsignedShortLe(value: Int) {
    write(value and 0xff)
    write((value ushr 8) and 0xff)
}

private fun OutputStream.writeUnsignedIntLe(value: Long) {
    require(value in 0..WAV_UINT32_MAX)
    write((value and 0xff).toInt())
    write(((value ushr 8) and 0xff).toInt())
    write(((value ushr 16) and 0xff).toInt())
    write(((value ushr 24) and 0xff).toInt())
}

private fun Context.displayNameFor(uri: Uri): String? {
    return contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && nameIndex >= 0) {
                cursor.getString(nameIndex)
            } else {
                null
            }
        }
}

private fun Context.persistReadAccess(uri: Uri) {
    runCatching {
        contentResolver.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION
        )
    }
}

private fun Context.importWavItems(
    uris: List<Uri>,
    knownUris: MutableSet<String>,
    repeatText: String
): ImportResult {
    val importedItems = mutableListOf<WavAudioItem>()
    var skippedCount = 0

    uris.forEach { uri ->
        val uriText = uri.toString()
        val displayName = displayNameFor(uri)
        val mimeType = contentResolver.getType(uri)
        if (!isWaveFile(displayName, mimeType) || !knownUris.add(uriText)) {
            skippedCount += 1
            return@forEach
        }

        val itemId = UUID.randomUUID().toString()
        val localPath = runCatching {
            persistReadAccess(uri)
            copyUriToAudioCache(uri = uri, itemId = itemId)
        }.getOrNull()

        if (localPath == null) {
            skippedCount += 1
            return@forEach
        }

        importedItems.add(
            WavAudioItem(
                uri = uriText,
                localPath = localPath,
                displayName = displayName ?: uri.lastPathSegment ?: "audio.wav",
                repeatText = repeatText,
                id = itemId
            )
        )
    }

    return ImportResult(
        items = importedItems,
        skippedCount = skippedCount
    )
}

private fun Context.copyUriToAudioCache(uri: Uri, itemId: String): String {
    val cacheDirectory = audioCacheDirectory().apply { mkdirs() }
    val targetFile = File(cacheDirectory, "$itemId.wav")
    try {
        contentResolver.openInputStream(uri)?.use { input ->
            targetFile.outputStream().use { output ->
                input.copyTo(output)
            }
        } ?: error("Unable to open audio input stream")
    } catch (exception: Exception) {
        targetFile.delete()
        throw exception
    }
    return targetFile.absolutePath
}

private fun Context.clearAudioCache() {
    audioCacheDirectory().deleteRecursively()
}

private fun Context.audioCacheDirectory(): File {
    return File(cacheDir, AUDIO_CACHE_DIRECTORY_NAME)
}

private fun deleteLocalFileIfOwned(item: WavAudioItem) {
    if (!item.deleteLocalFileOnRemove) return
    runCatching {
        File(item.localPath).delete()
    }
}

private fun Intent.debugAudioPaths(): List<String>? {
    val arrayPaths = getStringArrayExtra(DEBUG_AUDIO_PATHS_EXTRA)
        ?.mapNotNull { path -> path.trim().takeIf { it.isNotEmpty() } }
        ?.takeIf { paths -> paths.isNotEmpty() }
    if (arrayPaths != null) return arrayPaths

    val joinedPaths = getStringExtra(DEBUG_AUDIO_PATHS_EXTRA)
        ?.split('|', '\n', ',')
        ?.mapNotNull { path -> path.trim().takeIf { it.isNotEmpty() } }
        ?.takeIf { paths -> paths.isNotEmpty() }
    if (joinedPaths != null) return joinedPaths

    return getStringExtra(DEBUG_AUDIO_PATH_EXTRA)
        ?.trim()
        ?.takeIf { path -> path.isNotEmpty() }
        ?.let { path -> listOf(path) }
}

private fun createWavPickerIntent(): Intent {
    return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = WAV_PICKER_BASE_MIME_TYPE
        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        putExtra(Intent.EXTRA_MIME_TYPES, WAV_PICKER_MIME_TYPES)
        putExtra(Intent.EXTRA_LOCAL_ONLY, false)
        putExtra(DOCUMENT_PICKER_SHOW_ADVANCED_EXTRA, true)
    }
}

private fun Intent.selectedDocumentUris(): List<Uri> {
    val uris = mutableListOf<Uri>()
    clipData?.let { selectedItems ->
        for (index in 0 until selectedItems.itemCount) {
            selectedItems.getItemAt(index).uri?.let { uri -> uris.add(uri) }
        }
    }
    data?.let { uri -> uris.add(uri) }
    return uris.distinctBy { uri -> uri.toString() }
}

private fun isWaveFile(displayName: String?, mimeType: String?): Boolean {
    val lowerName = displayName.orEmpty().lowercase(Locale.US)
    val lowerType = mimeType.orEmpty().lowercase(Locale.US)
    return lowerName.endsWith(".wav") ||
        lowerType == "audio/wav" ||
        lowerType == "audio/x-wav" ||
        lowerType == "audio/wave" ||
        lowerType == "audio/vnd.wave" ||
        lowerType.contains("wav")
}

private fun sanitizeRepeatInput(value: String): String {
    val digits = value.filter { it.isDigit() }.take(4)
    val trimmed = digits.trimStart('0')
    return trimmed.ifEmpty {
        if (digits.isEmpty()) "" else "0"
    }
}

private fun sanitizeDelayInput(value: String): String {
    val result = StringBuilder()
    var hasDecimalPoint = false
    var wholeDigits = 0
    var fractionDigits = 0

    value.replace(',', '.').forEach { char ->
        when {
            char.isDigit() && hasDecimalPoint && fractionDigits < MAX_DELAY_FRACTION_DIGITS -> {
                result.append(char)
                fractionDigits += 1
            }
            char.isDigit() && !hasDecimalPoint && wholeDigits < MAX_DELAY_WHOLE_DIGITS -> {
                result.append(char)
                wholeDigits += 1
            }
            char == '.' && !hasDecimalPoint -> {
                if (result.isEmpty()) {
                    result.append('0')
                }
                result.append('.')
                hasDecimalPoint = true
            }
        }
    }

    val sanitized = result.toString()
    if (sanitized.isEmpty()) return ""

    val parts = sanitized.split('.', limit = 2)
    val wholePart = parts[0].trimStart('0').ifEmpty { "0" }
    return if (parts.size == 1) {
        wholePart
    } else {
        "$wholePart.${parts[1]}"
    }
}

private fun String.toPositiveRepeatCountOrNull(): Int? {
    return toIntOrNull()?.takeIf { it > 0 }
}

private fun String.toDelayMillisOrNull(): Long? {
    val seconds = replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 }
        ?: return null
    return (seconds * 1000.0).roundToLong()
}

private const val AUDIO_CACHE_DIRECTORY_NAME = "selected-wav"
private const val MAX_PLAYBACK_RETRIES = 2
private const val RETRY_DELAY_MILLIS = 300L
private const val MAX_DELAY_WHOLE_DIGITS = 4
private const val MAX_DELAY_FRACTION_DIGITS = 3
private const val AUDIO_COPY_BUFFER_SIZE = 32 * 1024
private const val AUDIO_DRAIN_POLL_INTERVAL_MILLIS = 10L
private const val AUDIO_DRAIN_TIMEOUT_GRACE_MILLIS = 2_000L
private const val AAUDIO_NON_BLOCKING_TIMEOUT_NANOS = 0L
private const val DELAY_POLL_INTERVAL_MILLIS = 25L
private const val PCM_16BIT_BYTES_PER_SAMPLE = 2
private const val PCM_24BIT_SIGN_BIT = 0x00800000
private const val PCM_24BIT_SIGN_EXTEND = -0x01000000
private val ROOT_ALSA_PASSTHROUGH_BITS = setOf(16, 24, 32)
private const val MILLIS_PER_SECOND = 1_000L
private const val MEDIA_PLAYER_COMPLETION_GRACE_MILLIS = 3_000L
private const val MEDIA_PLAYER_DEFAULT_TIMEOUT_MILLIS = 60_000L
private const val MEDIA_PLAYER_POLL_INTERVAL_MILLIS = 50L
private const val LOG_TAG = "AudioRepeater"
private const val DEBUG_AUDIO_PATH_EXTRA = "debugAudioPath"
private const val DEBUG_AUDIO_PATHS_EXTRA = "debugAudioPaths"
private const val DEBUG_REPEAT_COUNT_EXTRA = "debugRepeatCount"
private const val DEBUG_SAME_DELAY_EXTRA = "debugSameDelay"
private const val DEBUG_DIFFERENT_DELAY_EXTRA = "debugDifferentDelay"
private const val DEBUG_AAUDIO_EXCLUSIVE_EXTRA = "debugUseAaudioExclusive"
private const val DEBUG_DIRECT_ALSA_EXTRA = "debugUseDirectAlsa"
private const val DEBUG_LOW_LATENCY_AUDIOTRACK_EXTRA = "debugUseLowLatencyAudioTrack"
private const val DEBUG_FORCE_STEREO_ROUTE_ASSIST_EXTRA = "debugForceStereoRouteAssist"
private const val DEBUG_DIRECT_ALSA_PCM_DEVICE_EXTRA = "debugDirectAlsaPcmDevice"
private const val PERSISTED_PLAYLIST_PREFERENCES = "persisted-playlist"
private const val PERSISTED_PLAYLIST_PATHS = "paths"
private const val PERSISTED_PLAYLIST_REPEAT_COUNT = "repeat-count"
private const val PERSISTED_PLAYLIST_SAME_DELAY = "same-delay"
private const val PERSISTED_PLAYLIST_DIFFERENT_DELAY = "different-delay"
private const val PERSISTED_PLAYLIST_AAUDIO = "aaudio"
private const val PERSISTED_PLAYLIST_DIRECT_ALSA = "direct-alsa"
private const val PERSISTED_PLAYLIST_LOW_LATENCY = "low-latency"
private const val PERSISTED_PLAYLIST_ROUTE_ASSIST = "route-assist"
private const val PERSISTED_PLAYLIST_PCM_DEVICE = "pcm-device"
private const val PERSISTED_PLAYLIST_DISABLED_PATHS = "disabled-paths"
private const val ROOT_ALSA_CACHE_DIRECTORY_NAME = "root-alsa"
private const val ROOT_ALSA_TINYPLAY_PATH =
    "/data/local/tmp/audiorepeater_alsa/tinyplay_pcm_write"
private const val ROOT_ALSA_TINYPLAY_SHA256 =
    "a4c29d738c76e73c32b4ac7940de5a72974128c14f6a44aacdf9e82e2b8cf785"
private const val ROOT_ALSA_ROUTE_STARTUP_MILLIS = 750L
private const val ROOT_ALSA_PROOF_TAIL_MILLIS = 150L
private const val ROOT_ALSA_ROUTE_THREAD_JOIN_MILLIS = 1_000L
private const val ROOT_ALSA_PROCESS_TIMEOUT_SECONDS = 300L
private const val ROOT_ALSA_CLEANUP_TIMEOUT_SECONDS = 5L
private const val WAV_UINT32_MAX = 0xffffffffL
private const val DOCUMENT_PICKER_SHOW_ADVANCED_EXTRA = "android.provider.extra.SHOW_ADVANCED"
private const val WAV_CHUNK_HEADER_SIZE = 8
private const val WAV_MIN_FMT_CHUNK_SIZE = 16L
private const val WAV_EXTENSIBLE_FMT_CHUNK_SIZE = 40L
private const val WAV_EXTENSIBLE_MIN_EXTENSION_SIZE = 22
private const val WAV_FORMAT_PCM = 1
private const val WAV_FORMAT_IEEE_FLOAT = 3
private const val WAV_FORMAT_EXTENSIBLE = 0xfffe
private const val WAV_CHANNEL_MASK_MONO = 0x4
private const val WAV_CHANNEL_MASK_STEREO = 0x3

private val WAV_SUBFORMAT_GUID_TAIL = byteArrayOf(
    0x00,
    0x00,
    0x00,
    0x00,
    0x10,
    0x00,
    0x80.toByte(),
    0x00,
    0x00,
    0xaa.toByte(),
    0x00,
    0x38,
    0x9b.toByte(),
    0x71
)

private const val WAV_PICKER_BASE_MIME_TYPE = "audio/*"

private val WAV_PICKER_MIME_TYPES = arrayOf(
    "audio/wav",
    "audio/x-wav",
    "audio/wave",
    "audio/vnd.wave",
    "audio/*"
)
