package dev.companion.android

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import java.util.concurrent.Executors

class ProcessTextActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        overridePendingTransition(0, 0)
        super.onCreate(savedInstanceState)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()
        if (text.isNullOrBlank()) {
            finish()
            overridePendingTransition(0, 0)
            return
        }

        val client = PeerClient(applicationContext)
        if (!client.paired) {
            Toast.makeText(this, "Companion: Not paired with Mac", Toast.LENGTH_SHORT).show()
            finish()
            overridePendingTransition(0, 0)
            return
        }

        executor.execute {
            try {
                client.syncClipboardToMac(text)
                val preview = if (text.length > 25) text.take(25) + "…" else text
                runOnUiThread {
                    Toast.makeText(this@ProcessTextActivity, "Copied to Mac: $preview", Toast.LENGTH_SHORT).show()
                    finish()
                    overridePendingTransition(0, 0)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    Toast.makeText(this@ProcessTextActivity, "Failed to copy to Mac: ${e.message}", Toast.LENGTH_SHORT).show()
                    finish()
                    overridePendingTransition(0, 0)
                }
            }
        }
    }

    override fun finish() {
        super.finish()
        overridePendingTransition(0, 0)
    }

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }
}
