package com.a2m.audiorepeater

import java.io.File

internal fun rootShellCandidates(path: String?): List<String> =
    (path.orEmpty().split(File.pathSeparatorChar)
        .filter { directory -> directory.startsWith("/") }
        .map { directory -> "${directory.trimEnd('/')}/su" } + listOf(
        "/debug_ramdisk/su",
        "/sbin/su",
        "/system/xbin/su",
        "/system/bin/su",
        "/su/bin/su"
    )).distinct()

internal fun resolveRootShell(
    path: String? = System.getenv("PATH"),
    isExecutable: (String) -> Boolean = { candidate ->
        File(candidate).let { file -> file.isFile && file.canExecute() }
    }
): String = rootShellCandidates(path).firstOrNull(isExecutable)
    ?: error("Direct ALSA requires root access. The su executable was not found. Use a rooted device.")
