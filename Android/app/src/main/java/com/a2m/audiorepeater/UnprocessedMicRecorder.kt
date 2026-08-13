package com.a2m.audiorepeater

import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Environment
import android.os.SystemClock
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

internal data class MicRecordingResult(
    val file: File,
    val dataBytes: Long,
    val durationMillis: Long,
    val sampleRate: Int,
    val channelCount: Int,
    val audioSource: Int,
    val platformReportsUnprocessedSupport: Boolean?
)

/** Requests Android's UNPROCESSED microphone source and writes the captured PCM to WAV. */
internal class UnprocessedMicRecorder private constructor(
    private val audioRecord: AudioRecord,
    val outputFile: File,
    val sampleRate: Int,
    val channelCount: Int,
    val platformReportsUnprocessedSupport: Boolean?,
    private val bufferSize: Int
) {
    private val bytesWritten = AtomicLong(0L)
    private val workerFailure = AtomicReference<Throwable?>(null)
    private val startedAtMillis = SystemClock.elapsedRealtime()

    @Volatile
    private var stopRequested = false

    @Volatile
    private var completedResult: MicRecordingResult? = null

    private lateinit var writerThread: Thread

    val actualAudioSource: Int
        get() = audioRecord.audioSource

    fun start() {
        FileOutputStream(outputFile).use { output ->
            output.writePcm16WavHeader(
                sampleRate = sampleRate,
                channelCount = channelCount,
                dataBytes = 0L
            )
        }

        try {
            audioRecord.startRecording()
            check(audioRecord.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "UNPROCESSED AudioRecord did not enter the recording state"
            }
        } catch (exception: Throwable) {
            runCatching { audioRecord.release() }
            runCatching { outputFile.delete() }
            throw exception
        }

        writerThread = Thread(
            {
                val buffer = ByteArray(bufferSize)
                try {
                    FileOutputStream(outputFile, true).use { output ->
                        while (!stopRequested) {
                            val read = audioRecord.read(
                                buffer,
                                0,
                                buffer.size,
                                AudioRecord.READ_BLOCKING
                            )
                            when {
                                read > 0 -> {
                                    output.write(buffer, 0, read)
                                    bytesWritten.addAndGet(read.toLong())
                                }
                                stopRequested -> Unit
                                else -> error("UNPROCESSED AudioRecord read failed: $read")
                            }
                        }
                    }
                } catch (exception: Throwable) {
                    if (!stopRequested) workerFailure.set(exception)
                }
            },
            "AudioRepeater-UNPROCESSED-recorder"
        ).apply { start() }
    }

    fun requestStop() {
        stopRequested = true
        runCatching {
            if (audioRecord.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                audioRecord.stop()
            }
        }
    }

    @Synchronized
    fun finish(): MicRecordingResult {
        completedResult?.let { result -> return result }

        requestStop()
        if (::writerThread.isInitialized) {
            writerThread.join(RECORDING_THREAD_JOIN_MILLIS)
            check(!writerThread.isAlive) { "Timed out while finalizing UNPROCESSED recording" }
        }
        val finalAudioSource = actualAudioSource
        runCatching { audioRecord.release() }

        val dataBytes = bytesWritten.get()
        RandomAccessFile(outputFile, "rw").use { wav ->
            wav.seek(0L)
            wav.writePcm16WavHeader(
                sampleRate = sampleRate,
                channelCount = channelCount,
                dataBytes = dataBytes
            )
            wav.setLength(WAV_HEADER_BYTES + dataBytes)
        }

        workerFailure.get()?.let { exception ->
            throw IllegalStateException(
                "UNPROCESSED microphone writer failed; partial file: ${outputFile.absolutePath}",
                exception
            )
        }

        return MicRecordingResult(
            file = outputFile,
            dataBytes = dataBytes,
            durationMillis = SystemClock.elapsedRealtime() - startedAtMillis,
            sampleRate = sampleRate,
            channelCount = channelCount,
            audioSource = finalAudioSource,
            platformReportsUnprocessedSupport = platformReportsUnprocessedSupport
        ).also { result -> completedResult = result }
    }

    companion object {
        fun create(context: Context): UnprocessedMicRecorder {
            val minBufferSize = AudioRecord.getMinBufferSize(
                RECORDING_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            check(minBufferSize > 0) {
                "Invalid AudioRecord minimum buffer size: $minBufferSize"
            }
            val bufferSize = maxOf(minBufferSize * 2, RECORDING_SAMPLE_RATE / 5 * 2)
            val audioFormat = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RECORDING_SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val audioRecord = AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.UNPROCESSED)
                .setAudioFormat(audioFormat)
                .setBufferSizeInBytes(bufferSize)
                .build()

            if (audioRecord.state != AudioRecord.STATE_INITIALIZED) {
                audioRecord.release()
                error("UNPROCESSED AudioRecord initialization failed")
            }
            if (audioRecord.audioSource != MediaRecorder.AudioSource.UNPROCESSED) {
                val actualSource = audioRecord.audioSource
                audioRecord.release()
                error(
                    "Audio source mismatch: requested UNPROCESSED " +
                        "(${MediaRecorder.AudioSource.UNPROCESSED}), actual=$actualSource"
                )
            }

            val audioManager = context.getSystemService(AudioManager::class.java)
            val supportProperty = audioManager
                ?.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED)
                ?.let { value -> value.equals("true", ignoreCase = true) }
            val outputDirectory = File(
                context.getExternalFilesDir(Environment.DIRECTORY_MUSIC) ?: context.filesDir,
                "AudioRepeater/recordings"
            ).apply { mkdirs() }
            check(outputDirectory.isDirectory) {
                "Could not create recording directory: ${outputDirectory.absolutePath}"
            }
            val timestamp = SimpleDateFormat(
                "yyyyMMdd_HHmmss_SSS",
                Locale.US
            ).format(Date())
            val outputFile = File(
                outputDirectory,
                "audiorepeater_unprocessed_$timestamp.wav"
            )

            return UnprocessedMicRecorder(
                audioRecord = audioRecord,
                outputFile = outputFile,
                sampleRate = RECORDING_SAMPLE_RATE,
                channelCount = RECORDING_CHANNEL_COUNT,
                platformReportsUnprocessedSupport = supportProperty,
                bufferSize = bufferSize
            )
        }
    }
}

private fun FileOutputStream.writePcm16WavHeader(
    sampleRate: Int,
    channelCount: Int,
    dataBytes: Long
) {
    writePcm16WavHeaderBytes(sampleRate, channelCount, dataBytes)
}

private fun RandomAccessFile.writePcm16WavHeader(
    sampleRate: Int,
    channelCount: Int,
    dataBytes: Long
) {
    writePcm16WavHeaderBytes(sampleRate, channelCount, dataBytes)
}

private fun FileOutputStream.writePcm16WavHeaderBytes(
    sampleRate: Int,
    channelCount: Int,
    dataBytes: Long
) {
    val header = buildPcm16WavHeader(sampleRate, channelCount, dataBytes)
    write(header)
}

private fun RandomAccessFile.writePcm16WavHeaderBytes(
    sampleRate: Int,
    channelCount: Int,
    dataBytes: Long
) {
    val header = buildPcm16WavHeader(sampleRate, channelCount, dataBytes)
    write(header)
}

internal fun buildPcm16WavHeader(
    sampleRate: Int,
    channelCount: Int,
    dataBytes: Long
): ByteArray {
    require(dataBytes in 0..WAV_MAX_DATA_BYTES) { "WAV recording is too large: $dataBytes bytes" }
    val blockAlign = channelCount * 2
    val byteRate = sampleRate * blockAlign
    return ByteArray(WAV_HEADER_BYTES.toInt()).also { header ->
        fun ascii(offset: Int, value: String) {
            value.toByteArray(StandardCharsets.US_ASCII).copyInto(header, offset)
        }
        fun shortLe(offset: Int, value: Int) {
            header[offset] = (value and 0xff).toByte()
            header[offset + 1] = ((value ushr 8) and 0xff).toByte()
        }
        fun intLe(offset: Int, value: Long) {
            repeat(4) { index ->
                header[offset + index] = ((value ushr (index * 8)) and 0xff).toByte()
            }
        }

        ascii(0, "RIFF")
        intLe(4, 36L + dataBytes)
        ascii(8, "WAVE")
        ascii(12, "fmt ")
        intLe(16, 16L)
        shortLe(20, 1)
        shortLe(22, channelCount)
        intLe(24, sampleRate.toLong())
        intLe(28, byteRate.toLong())
        shortLe(32, blockAlign)
        shortLe(34, 16)
        ascii(36, "data")
        intLe(40, dataBytes)
    }
}

private const val RECORDING_SAMPLE_RATE = 48_000
private const val RECORDING_CHANNEL_COUNT = 1
private const val RECORDING_THREAD_JOIN_MILLIS = 5_000L
private const val WAV_HEADER_BYTES = 44L
private const val WAV_MAX_DATA_BYTES = 0xffff_ffffL - 36L
