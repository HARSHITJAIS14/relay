package dev.companion.android

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import dev.companion.core.*
import java.io.DataInputStream
import java.security.KeyStore
import java.security.cert.CertificateFactory
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory

/** Disposable test identity lives only in the test APK, never the product APK. */
class DeviceProbeTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    @Test fun testProtocolOnAndroidRuntime() {
        val bytes = instrumentation.context.assets.open("hello.json").use { it.readBytes() }
        val hello = ControlCodec.decode(bytes)
        assertEquals("Test phone", hello.body.deviceName)
        val frame = ControlCodec.frame(hello)
        for (split in 0..frame.size) {
            val received = mutableListOf<ControlEnvelope>()
            val decoder = FrameDecoder()
            decoder.append(frame.copyOfRange(0, split)) { received.add(it) }
            decoder.append(frame.copyOfRange(split, frame.size)) { received.add(it) }
            assertEquals(listOf(hello), received)
        }
    }

    @Test fun testMutuallyAuthenticatedTLSProbe() {
        val assets = instrumentation.context.assets
        val password = "probe-only".toCharArray()
        val client = KeyStore.getInstance("PKCS12").apply {
            assets.open("client.p12").use { load(it, password) }
        }
        val trust = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null)
            val cert = assets.open("ca.crt").use {
                CertificateFactory.getInstance("X.509").generateCertificate(it)
            }
            setCertificateEntry("probe-ca", cert)
        }
        val keys = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
            init(client, password)
        }
        val trustManagers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm()).apply {
            init(trust)
        }
        val context = SSLContext.getInstance("TLS").apply {
            init(keys.keyManagers, trustManagers.trustManagers, null)
        }
        val socket = context.socketFactory.createSocket() as SSLSocket
        socket.use {
            it.soTimeout = 10000
            it.sslParameters = it.sslParameters.apply { endpointIdentificationAlgorithm = "HTTPS" }
            it.connect(java.net.InetSocketAddress("localhost", 18443), 10000)
            it.startHandshake()
            assertTrue(it.session.protocol.startsWith("TLSv1."))
            val hello = ControlCodec.decode(assets.open("hello.json").use { input -> input.readBytes() })
            it.outputStream.write(ControlCodec.frame(hello))
            it.outputStream.flush()
            val input = DataInputStream(it.inputStream)
            val length = input.readInt()
            assertTrue(length in 1..ControlCodec.MAX_PAYLOAD_BYTES)
            val response = ByteArray(length)
            input.readFully(response)
            assertEquals(hello, ControlCodec.decode(response))
        }
    }
}
