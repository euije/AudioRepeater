package com.a2m.audiorepeater

import android.os.Build
import android.system.Os
import java.util.concurrent.TimeUnit

internal fun deviceSupportsInitAlsa(): Boolean = supportsInitAlsa(
    Build.DEVICE, Build.VERSION.SDK_INT, Build.FINGERPRINT,
    runCatching { Os.uname().release }.getOrDefault("")
)

// Run on Dispatchers.IO. Presence of a su executable alone does not prove root access.
internal fun hasRootAccess(): Boolean = runCatching {
    val process = ProcessBuilder(resolveRootShell(), "-c", "id -u")
        .redirectErrorStream(true).start()
    try {
        process.outputStream.close()
        process.waitFor(5, TimeUnit.SECONDS) && process.exitValue() == 0 &&
            process.inputStream.bufferedReader().use { it.readText().trim() == "0" }
    } finally {
        process.destroyForcibly()
        process.inputStream.close()
        process.errorStream.close()
    }
}.getOrDefault(false)
