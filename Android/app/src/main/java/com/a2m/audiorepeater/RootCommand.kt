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
    ?: error("Direct ALSA에는 루트 권한이 필요합니다. su 실행 파일을 찾을 수 없습니다. 루팅된 기기에서 실행하세요.")
