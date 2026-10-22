package dev.companion.android

import android.content.Context
import android.content.ContextWrapper
import android.app.NotificationManager
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID

class LargeFileTest {
    @Test fun stagesOneGBWithProgressAndRejectsOversize() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val prefix = "large-file-test-${UUID.randomUUID()}-"
        val root = File(base.cacheDir, prefix).apply { mkdirs() }
        // Isolate test queues/preferences; never alter the user's pairing.
        val context = object : ContextWrapper(base) {
            override fun getFilesDir(): File = root
            override fun getSharedPreferences(name: String, mode: Int) = base.getSharedPreferences(prefix + name, mode)
        }
        val prefs = context.getSharedPreferences("companion-peer-v1", Context.MODE_PRIVATE)
        prefs.edit().putBoolean("paired", true).putString("pin", "test-only").commit()
        val previousProgress = TransferProgressCenter.latest
        try {
            val client = PeerClient(context)
            val events = mutableListOf<TransferProgress>()
            client.onTransferProgress = { events.add(it) }
            val source = File(root, "one-gb-test.bin")
            RandomAccessFile(source, "rw").use { it.setLength(1_000_000_000L) }
            val manifest = client.stageFile(source)
            assertEquals(1_000_000_000L, JSONObject(manifest.readText()).getLong("size"))
            assertEquals(TransferProgress.State.PREPARING, events.first().state)
            assertEquals(TransferProgress.State.QUEUED, events.last().state)
            assertTrue(events.any { it.state == TransferProgress.State.PREPARING && it.transferredBytes > 0 })
            assertTrue(events.all { it.transferredBytes in 0..1_000_000_000L })
            assertEquals(events.filter { it.state == TransferProgress.State.PREPARING }.map { it.transferredBytes }.sorted(),
                events.filter { it.state == TransferProgress.State.PREPARING }.map { it.transferredBytes })
            File(manifest.parentFile, manifest.nameWithoutExtension + ".data").delete()
            manifest.delete()
            RandomAccessFile(source, "rw").use { it.setLength(1_000_000_001L) }
            try { client.stageFile(source); fail("File above 1 GB was accepted") } catch (_: IllegalArgumentException) {}
        } finally {
            root.deleteRecursively()
            base.deleteSharedPreferences(prefix + "companion-peer-v1")
            previousProgress?.let { TransferProgressCenter.publish(it) }
            base.getSystemService(NotificationManager::class.java).cancel(1003)
        }
    }

    @Test fun backgroundProgressIsReplayedAndListenersDetach() {
        val first = TransferProgress("test", "test.bin", TransferProgress.Direction.RECEIVE, 64, 128, TransferProgress.State.TRANSFERRING)
        val previous = TransferProgressCenter.latest
        TransferProgressCenter.publish(first)
        val events = mutableListOf<TransferProgress>()
        val listener: (TransferProgress) -> Unit = { events.add(it) }
        TransferProgressCenter.addListener(listener)
        try {
            assertEquals(first, events.single())
            TransferProgressCenter.publish(first.copy(transferredBytes = 128, state = TransferProgress.State.VERIFYING))
            assertEquals(2, events.size)
            TransferProgressCenter.removeListener(listener)
            TransferProgressCenter.publish(first.copy(state = TransferProgress.State.COMPLETED))
            assertEquals(2, events.size)
        } finally {
            TransferProgressCenter.removeListener(listener)
            previous?.let { TransferProgressCenter.publish(it) }
        }
    }
}
