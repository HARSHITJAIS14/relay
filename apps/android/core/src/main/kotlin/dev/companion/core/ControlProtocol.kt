package dev.companion.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID

enum class Failure { INVALID_LENGTH, MALFORMED_ENVELOPE, INCOMPATIBLE_VERSION, UNSUPPORTED_MESSAGE }
class ProtocolException(val failure: Failure) : Exception(failure.name)
data class Hello(val deviceName: String, val capabilities: List<String>)
data class ControlEnvelope(
    val messageId: String,
    val sessionId: String,
    val body: Hello,
    val protocolMajor: Int = 1,
    val protocolMinor: Int = 0,
    val type: String = "session.hello"
) {
    fun validate() {
        if (protocolMajor != 1) throw ProtocolException(Failure.INCOMPATIBLE_VERSION)
        if (type != "session.hello") throw ProtocolException(Failure.UNSUPPORTED_MESSAGE)
        val validId = runCatching { UUID.fromString(messageId).toString().equals(messageId, true) }.getOrDefault(false)
        fun bounded(value: String, limit: Int) = value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= limit
        if (protocolMinor < 0 || !validId || !bounded(sessionId, 128) ||
            !bounded(body.deviceName, 128) || body.capabilities.size > 32 ||
            body.capabilities.any { !bounded(it, 64) } ||
            body.capabilities.distinct().size != body.capabilities.size
        ) throw ProtocolException(Failure.MALFORMED_ENVELOPE)
    }
}

object ControlCodec {
    const val MAX_PAYLOAD_BYTES = 512 * 1024

    fun decode(payload: ByteArray): ControlEnvelope {
        if (payload.isEmpty() || payload.size > MAX_PAYLOAD_BYTES) throw ProtocolException(Failure.INVALID_LENGTH)
        try {
            val text = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(payload)).toString()
            val json = JSONObject(text)
            fun string(obj: JSONObject, key: String) = obj.get(key) as? String
                ?: throw ProtocolException(Failure.MALFORMED_ENVELOPE)
            fun integer(key: String) = json.get(key) as? Int
                ?: throw ProtocolException(Failure.MALFORMED_ENVELOPE)
            val body = json.getJSONObject("body")
            val capabilities = body.getJSONArray("capabilities")
            return ControlEnvelope(
                string(json, "messageId"), string(json, "sessionId"),
                Hello(string(body, "deviceName"), (0 until capabilities.length()).map {
                    capabilities.get(it) as? String ?: throw ProtocolException(Failure.MALFORMED_ENVELOPE)
                }),
                integer("protocolMajor"), integer("protocolMinor"), string(json, "type")
            ).also { it.validate() }
        } catch (error: ProtocolException) {
            throw error
        } catch (_: Exception) {
            throw ProtocolException(Failure.MALFORMED_ENVELOPE)
        }
    }

    fun frame(envelope: ControlEnvelope): ByteArray {
        envelope.validate()
        val payload = JSONObject()
            .put("protocolMajor", envelope.protocolMajor).put("protocolMinor", envelope.protocolMinor)
            .put("type", envelope.type).put("messageId", envelope.messageId)
            .put("sessionId", envelope.sessionId)
            .put("body", JSONObject().put("deviceName", envelope.body.deviceName)
                .put("capabilities", JSONArray(envelope.body.capabilities)))
            .toString().toByteArray(Charsets.UTF_8)
        if (payload.size > MAX_PAYLOAD_BYTES) throw ProtocolException(Failure.INVALID_LENGTH)
        return ByteBuffer.allocate(4 + payload.size).putInt(payload.size).put(payload).array()
    }
}

class FrameDecoder {
    private var header = 0L
    private var headerBytes = 0
    private var expectedLength: Int? = null
    private val payload = ByteArrayOutputStream()

    fun append(bytes: ByteArray, onFrame: (ControlEnvelope) -> Unit) {
        try {
            for (byte in bytes) {
                val expected = expectedLength
                if (expected == null) {
                    header = (header shl 8) or (byte.toLong() and 255)
                    headerBytes++
                    if (headerBytes == 4) {
                        if (header !in 1..ControlCodec.MAX_PAYLOAD_BYTES.toLong()) {
                            throw ProtocolException(Failure.INVALID_LENGTH)
                        }
                        expectedLength = header.toInt()
                        header = 0
                        headerBytes = 0
                    }
                } else {
                    payload.write(byte.toInt())
                    if (payload.size() == expected) {
                        val message = ControlCodec.decode(payload.toByteArray())
                        payload.reset()
                        expectedLength = null
                        onFrame(message)
                    }
                }
            }
        } catch (error: Exception) {
            header = 0
            headerBytes = 0
            expectedLength = null
            payload.reset()
            throw error
        }
    }
}
