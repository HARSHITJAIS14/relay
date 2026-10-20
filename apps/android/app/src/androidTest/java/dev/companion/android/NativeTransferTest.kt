package dev.companion.android

import android.content.ContentValues
import android.provider.MediaStore
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Exercises the production client against the real Swift server on a LAN.
 * Pairing still requires approval in the Mac UI. No auto-approval or hidden trust path.
 */
class NativeTransferTest {
    @Test fun pairingAndUpload() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val args = InstrumentationRegistry.getArguments()
        val client = PeerClient(context)
        if (!client.paired) {
            val invitation = args.getString("invitation") ?: error("Supply an invitation from the Mac UI")
            client.beginPairing(invitation)
            val deadline = System.currentTimeMillis() + 120000
            while (!client.paired && System.currentTimeMillis() < deadline) {
                Thread.sleep(1000)
                client.pollPairing()
            }
        }
        assertTrue("Approve the matching pairing code in the Mac UI", client.paired)
        assertEquals("Connected to Mac", client.checkConnection())
        val payload = ByteArray(1024 * 1024 + 17) { (it % 251).toByte() }
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, "companion-phone-test.bin")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val source = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)!!
        try {
            context.contentResolver.openOutputStream(source)!!.use { it.write(payload) }
            client.stage(source)
            val result = client.sendPending()
            assertEquals("Sent companion-phone-test.bin", result)
            assertEquals("Connected to Mac", PeerClient(context).checkConnection())
        } finally {
            context.contentResolver.delete(source, null, null)
        }
    }

    @Test fun receiveQueuedFile() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val result = PeerClient(context).receiveNext()
        assertNotNull("Queue a synthetic file in the Mac app before this test", result)
        assertTrue(result!!.startsWith("Saved "))
    }
}
