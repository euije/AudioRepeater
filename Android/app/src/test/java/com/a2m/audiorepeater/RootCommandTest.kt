package com.a2m.audiorepeater

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class RootCommandTest {
    @Test
    fun samsungMagiskOutsidePathIsFound() {
        val path = listOf("/system/bin", "/system/xbin").joinToString(File.pathSeparator)
        assertEquals("/debug_ramdisk/su", resolveRootShell(path) { it == "/debug_ramdisk/su" })
    }

    @Test
    fun existingPathRootShellKeepsPriority() {
        assertEquals("/system/bin/su", resolveRootShell("/system/bin") {
            it == "/system/bin/su" || it == "/debug_ramdisk/su"
        })
    }

    @Test
    fun emptyAndRelativePathEntriesAreNotExecuted() {
        val path = listOf("", ".", "local/bin", "/system/bin", "/system/bin").joinToString(File.pathSeparator)
        val candidates = rootShellCandidates(path)
        assertTrue(candidates.all { it.startsWith("/") })
        assertFalse(candidates.contains("su"))
        assertEquals(candidates.size, candidates.distinct().size)
    }

    @Test
    fun missingRootExplainsTheRequiredDeviceState() {
        val failure = runCatching { resolveRootShell(null) { false } }.exceptionOrNull()
        assertTrue(failure is IllegalStateException)
        assertTrue(failure?.message.orEmpty().contains("루트 권한이 필요"))
    }
}
