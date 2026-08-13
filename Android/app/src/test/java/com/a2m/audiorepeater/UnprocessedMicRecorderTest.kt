package com.a2m.audiorepeater

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class UnprocessedMicRecorderTest {
    @Test
    fun pcm16WavHeaderContainsExpectedFormatAndSizes() {
        val header = buildPcm16WavHeader(
            sampleRate = 48_000,
            channelCount = 1,
            dataBytes = 96_000L
        )

        assertEquals(44, header.size)
        assertArrayEquals("RIFF".toByteArray(), header.copyOfRange(0, 4))
        assertEquals(96_036L, header.uint32LeAt(4))
        assertArrayEquals("WAVE".toByteArray(), header.copyOfRange(8, 12))
        assertEquals(1, header.uint16LeAt(20))
        assertEquals(1, header.uint16LeAt(22))
        assertEquals(48_000L, header.uint32LeAt(24))
        assertEquals(96_000L, header.uint32LeAt(28))
        assertEquals(2, header.uint16LeAt(32))
        assertEquals(16, header.uint16LeAt(34))
        assertArrayEquals("data".toByteArray(), header.copyOfRange(36, 40))
        assertEquals(96_000L, header.uint32LeAt(40))
    }
}

private fun ByteArray.uint16LeAt(offset: Int): Int =
    (this[offset].toInt() and 0xff) or
        ((this[offset + 1].toInt() and 0xff) shl 8)

private fun ByteArray.uint32LeAt(offset: Int): Long =
    (0 until 4).fold(0L) { value, index ->
        value or ((this[offset + index].toLong() and 0xff) shl (index * 8))
    }
