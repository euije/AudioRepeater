package com.a2m.audiorepeater

import android.content.Context
import java.io.File
import java.security.MessageDigest

internal data class PreparedMmapHelper(val path: String, val sha256: String)

internal fun usesPixel10Mmap(device: String, sdk: Int): Boolean = device == "frankel" && sdk == 37

internal object Pixel10MmapHelper {
    fun prepare(context: Context): PreparedMmapHelper {
        val bytes = context.assets.open("pixel10_mmap/arm64-v8a/player").use { it.readBytes() }
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val file = File(context.filesDir, "pixel10-mmap-player-$hash")
        if (!file.exists()) {
            val temporary = File(context.filesDir, "pixel10-mmap-player.tmp")
            temporary.writeBytes(bytes)
            check(temporary.renameTo(file)) { "Cannot install Pixel 10 ALSA helper" }
        }
        val storedHash = MessageDigest.getInstance("SHA-256").digest(file.readBytes())
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        check(storedHash == hash && file.setExecutable(true, true)) { "Invalid Pixel 10 ALSA helper" }
        return PreparedMmapHelper(file.absolutePath, hash)
    }
}
