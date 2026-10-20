package dev.companion.core

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class ControlProtocolTest {
    private fun fixture(name: String) = File(
        System.getProperty("companion.fixtures"), "$name.json"
    ).readBytes()

    @Test fun sharedHelloFixture() {
        val hello = ControlCodec.decode(fixture("hello"))
        assertEquals("Test phone", hello.body.deviceName)
        assertEquals(emptyList<String>(), hello.body.capabilities)
    }

    @Test fun everyPossibleSplitOfFrame() {
        val hello = ControlCodec.decode(fixture("hello"))
        val bytes = ControlCodec.frame(hello)
        for (split in 0..bytes.size) {
            val decoder = FrameDecoder()
            val received = mutableListOf<ControlEnvelope>()
            decoder.append(bytes.copyOfRange(0, split)) { received.add(it) }
            decoder.append(bytes.copyOfRange(split, bytes.size)) { received.add(it) }
            assertEquals("Split at $split", listOf(hello), received)
        }
    }

    @Test fun coalescedAndBytewiseFrames() {
        val hello = ControlCodec.decode(fixture("hello"))
        val frame = ControlCodec.frame(hello)
        val decoder = FrameDecoder()
        val received = mutableListOf<ControlEnvelope>()
        decoder.append(frame + frame) { received.add(it) }
        frame.forEach { byte -> decoder.append(byteArrayOf(byte)) { received.add(it) } }
        assertEquals(listOf(hello, hello, hello), received)
    }

    @Test fun rejectLengthsBeforeAllocation() {
        listOf(byteArrayOf(0, 0, 0, 0), byteArrayOf(0, 8, 0, 1), byteArrayOf(-1, -1, -1, -1))
            .forEach { header ->
                val error = assertThrows(ProtocolException::class.java) { FrameDecoder().append(header) {} }
                assertEquals(Failure.INVALID_LENGTH, error.failure)
            }
    }

    @Test fun sharedInvalidFixtures() {
        mapOf("unsupported-version" to Failure.INCOMPATIBLE_VERSION, "invalid-id" to Failure.MALFORMED_ENVELOPE)
            .forEach { (name, expected) ->
                val error = assertThrows(ProtocolException::class.java) { ControlCodec.decode(fixture(name)) }
                assertEquals(expected, error.failure)
            }
    }

    @Test fun malformedPayloadAndReset() {
        val decoder = FrameDecoder()
        assertThrows(ProtocolException::class.java) { decoder.append(byteArrayOf(0, 0, 0, 1, -1)) {} }
        val hello = ControlCodec.decode(fixture("hello"))
        var count = 0
        decoder.append(ControlCodec.frame(hello)) { count++ }
        assertEquals(1, count)
    }
}
