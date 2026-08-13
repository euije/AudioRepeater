package com.a2m.audiorepeater

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DirectAlsaRuntimeProofTest {
    private val pcmNode = "/dev/snd/pcmC0D13p"

    @Test
    fun livePcmProofIsAccepted() {
        val output = successfulOutput("A2M_ALSA_PCM_LIVE node=$pcmNode pid=123")

        assertNull(directAlsaRuntimeFailure(output, pcmNode, exitCode = 0))
        assertFalse(isDirectAlsaShortCompletion(output, pcmNode))
    }

    @Test
    fun livePcmFileDescriptorProofIsAccepted() {
        val output = successfulOutput("A2M_ALSA_PCM_FD_LIVE node=$pcmNode pid=123")

        assertNull(directAlsaRuntimeFailure(output, pcmNode, exitCode = 0))
    }

    @Test
    fun shortCompletionIsRejectedEvenWhenLegacyOutputClaimsCompletion() {
        val output = """
            A2M_ALSA_ROOT uid=0(root)
            A2M_ALSA_ROUTE_ENABLED On
            A2M_ALSA_PCM_FDS /dev/null
            A2M_ALSA_PCM_SHORT_COMPLETE requested_node=$pcmNode
            A2M_ALSA_PCM_COMPLETE node=$pcmNode
            A2M_ALSA_ROUTE_DISABLED Off
        """.trimIndent()

        assertTrue(isDirectAlsaShortCompletion(output, pcmNode))
        assertEquals(
            "Direct ALSA helper exited before PCM playback became active: $pcmNode",
            directAlsaRuntimeFailure(output, pcmNode, exitCode = 0)
        )
    }

    @Test
    fun nonZeroRootExitIsRejected() {
        assertEquals(
            "Direct ALSA root process failed: exit=25",
            directAlsaRuntimeFailure("A2M_ALSA_PCM_NODE_MISMATCH", pcmNode, exitCode = 25)
        )
    }

    @Test
    fun helperPlaybackErrorIsRejected() {
        val output = successfulOutput("A2M_ALSA_PCM_LIVE node=$pcmNode pid=123") +
            "\nError playing sample"

        assertEquals(
            "Direct ALSA helper reported a playback error",
            directAlsaRuntimeFailure(output, pcmNode, exitCode = 0)
        )
    }

    @Test
    fun missingLivePcmProofIsRejected() {
        val output = successfulOutput("A2M_ALSA_PCM_STATUS state: PREPARED")

        assertEquals(
            "Direct ALSA runtime proof is incomplete",
            directAlsaRuntimeFailure(output, pcmNode, exitCode = 0)
        )
    }

    private fun successfulOutput(activityProof: String): String = """
        A2M_ALSA_ROOT uid=0(root)
        A2M_ALSA_ROUTE_ENABLED On
        A2M_ALSA_PCM_FDS $pcmNode
        $activityProof
        A2M_ALSA_PCM_COMPLETE node=$pcmNode
        A2M_ALSA_ROUTE_DISABLED Off
    """.trimIndent()
}
