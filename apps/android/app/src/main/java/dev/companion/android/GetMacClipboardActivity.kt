package dev.companion.android

import android.app.Activity
import android.os.Bundle
import android.widget.Toast
import java.util.concurrent.Executors

/**
 * Headless activity that pulls the latest Mac clipboard on demand and applies it
 * to the phone's system clipboard without opening the main app or popping recurring overlays.
 */
class GetMacClipboardActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        overridePendingTransition(0, 0)
        super.onCreate(savedInstanceState)
        val client = PeerClient(applicationContext)
        if (!client.paired) {
            Toast.makeText(this, "Companion: Not paired with Mac", Toast.LENGTH_SHORT).show()
            finish()
            overridePendingTransition(0, 0)
            return
        }

        executor.execute {
            try {
                val text = client.applyLatestMacClipboard()
                runOnUiThread {
                    if (text.isNullOrBlank()) {
                        Toast.makeText(this@GetMacClipboardActivity, "No new clipboard item from Mac", Toast.LENGTH_SHORT).show()
                    } else {
                        val preview = if (text.length > 25) text.take(25) + "…" else text
                        Toast.makeText(this@GetMacClipboardActivity, "Pasted from Mac: $preview", Toast.LENGTH_SHORT).show()
                    }
                    finish()
                    overridePendingTransition(0, 0)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    Toast.makeText(this@GetMacClipboardActivity, "Failed to get from Mac: ${e.message}", Toast.LENGTH_SHORT).show()
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
