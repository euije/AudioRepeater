package com.a2m.audiorepeater

internal fun isDirectAlsaPcmOpenFailure(rootOutput: String, pcmNode: String): Boolean =
    rootOutput.contains("A2M_ALSA_PCM_FAILED") &&
        rootOutput.contains("Unable to open PCM device") &&
        rootOutput.contains("pcm_hw_open: cannot open device '$pcmNode'") &&
        !rootOutput.contains("A2M_ALSA_PCM_FD_LIVE node=$pcmNode") &&
        !rootOutput.contains("A2M_ALSA_PCM_LIVE node=$pcmNode") &&
        !rootOutput.contains("A2M_ALSA_PCM_COMPLETE node=$pcmNode")

internal fun isDirectAlsaShortCompletion(rootOutput: String, pcmNode: String): Boolean =
    rootOutput.contains("A2M_ALSA_PCM_SHORT_COMPLETE requested_node=$pcmNode")

internal fun directAlsaRuntimeFailure(
    rootOutput: String,
    pcmNode: String,
    exitCode: Int,
    requiresMmapProgress: Boolean = false
): String? {
    if (
        rootOutput.contains("Error playing sample", ignoreCase = true) ||
        rootOutput.contains("Unable to open PCM", ignoreCase = true) ||
        rootOutput.contains("A2M_ALSA_PCM_FAILED")
    ) {
        return "Direct ALSA helper reported a playback error"
    }
    if (isDirectAlsaShortCompletion(rootOutput, pcmNode)) {
        return "Direct ALSA helper exited before PCM playback became active: $pcmNode"
    }
    if (exitCode != 0) {
        return "Direct ALSA root process failed: exit=$exitCode"
    }
    if (requiresMmapProgress && (
            !rootOutput.contains("A2M_ALSA_MMAP_CONFIG api=pcm_mmap_write flags=MMAP|NOIRQ") ||
            !rootOutput.contains("A2M_ALSA_MMAP_RENDERED core_frames=") ||
            !rootOutput.contains("A2M_ALSA_MMAP_STOP state=SETUP")
        )) {
        return "Direct ALSA mmap rendering proof is incomplete"
    }

    val pcmBecameActive =
        rootOutput.contains("A2M_ALSA_PCM_LIVE node=$pcmNode") ||
            rootOutput.contains("A2M_ALSA_PCM_FD_LIVE node=$pcmNode")
    val proofIsComplete =
        rootOutput.contains("A2M_ALSA_ROOT uid=0(root)") &&
            rootOutput.contains("A2M_ALSA_ROUTE_ENABLED") &&
            rootOutput.contains("A2M_ALSA_PCM_FDS") &&
            pcmBecameActive &&
            rootOutput.contains("A2M_ALSA_PCM_COMPLETE node=$pcmNode") &&
            rootOutput.contains("A2M_ALSA_ROUTE_DISABLED")

    return if (proofIsComplete) null else "Direct ALSA runtime proof is incomplete"
}
