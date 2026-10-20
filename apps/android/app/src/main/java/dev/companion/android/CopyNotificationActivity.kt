package dev.companion.android

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.view.View
import android.widget.Toast
import java.util.concurrent.Executors

class CopyNotificationActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        overridePendingTransition(0, 0)
        super.onCreate(savedInstanceState)
        setContentView(View(this).apply { setBackgroundColor(0) })
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !handled) {
            handled = true
            readAndSyncClipboard()
        }
    }

    override fun onResume() {
        super.onResume()
        window.decorView.postDelayed({
            if (!handled) {
                handled = true
                readAndSyncClipboard()
            }
        }, 150)
    }

    private fun readAndSyncClipboard() {
        val client = PeerClient(applicationContext)
        if (!client.paired) {
            Toast.makeText(this, "Companion: Not paired with Mac", Toast.LENGTH_SHORT).show()
            finish()
            overridePendingTransition(0, 0)
            return
        }

        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
        val text = clip?.coerceToText(this)?.toString()?.trim()

        if (text.isNullOrBlank()) {
            Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show()
            finish()
            overridePendingTransition(0, 0)
            return
        }

        executor.execute {
            try {
                client.syncClipboardToMac(text)
                val preview = if (text.length > 25) text.take(25) + "…" else text
                runOnUiThread {
                    Toast.makeText(this@CopyNotificationActivity, "Copied to Mac: $preview", Toast.LENGTH_SHORT).show()
                    finish()
                    overridePendingTransition(0, 0)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    Toast.makeText(this@CopyNotificationActivity, "Failed to copy to Mac: ${e.message}", Toast.LENGTH_SHORT).show()
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
