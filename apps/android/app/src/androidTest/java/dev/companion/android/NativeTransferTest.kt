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
        // A DHCP address can change without changing the paired Mac's identity.
        // Keep the new endpoint only after the production certificate-pin check succeeds.
        args.getString("host")?.let { host ->
            assertTrue("A current paired Mac is required", client.paired)
            val preferences = context.getSharedPreferences("companion-peer-v1", android.content.Context.MODE_PRIVATE)
            val previousHost = client.host
            check(preferences.edit().putString("host", host).commit())
            try {
                assertEquals("Connected to Mac", client.checkConnection())
            } catch (failure: Throwable) {
                check(preferences.edit().putString("host", previousHost).commit())
                throw failure
            }
        }
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
        val args = InstrumentationRegistry.getArguments()
        val expectedName = args.getString("expectedName")
        val client = PeerClient(context)
        var result = client.receiveNext()
        if (expectedName != null) {
            // Earlier synthetic test files may still be queued from interrupted runs.
            var attempts = 0
            while (result?.contains(expectedName) != true && attempts++ < 20) {
                result = client.receiveNext()
            }
        }
        assertNotNull("Queue a synthetic file in the Mac app before this test", result)
        assertTrue(result!!.startsWith("Saved ") || result.startsWith("Already saved "))
        if (expectedName != null) {
            assertTrue("Expected this run's file: $expectedName, got $result", result.contains(expectedName))
            val expectedHash = args.getString("expectedSha256") ?: error("Supply expectedSha256")
            context.contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.RELATIVE_PATH} = ?",
                arrayOf(expectedName, "Download/Relay/"), null
            )!!.use { cursor ->
                assertTrue("Received file must be published in Downloads/Relay", cursor.moveToFirst())
                val uri = android.content.ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cursor.getLong(0))
                val bytes = context.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
                assertEquals("Published file bytes must match the Mac payload", expectedHash, sha256(bytes))
            }
        }
    }
}
