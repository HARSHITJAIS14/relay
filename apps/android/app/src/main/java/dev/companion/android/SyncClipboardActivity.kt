package dev.companion.android

import android.app.Activity
import android.os.Bundle
import android.view.View
import android.widget.Toast
import java.util.concurrent.Executors

class SyncClipboardActivity : Activity() {
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
            executeSmartSync()
        }
    }

    override fun onResume() {
        super.onResume()
        window.decorView.postDelayed({
            if (!handled) {
                handled = true
                executeSmartSync()
            }
        }, 150)
    }

    private fun executeSmartSync() {
        val client = PeerClient(applicationContext)
        if (!client.paired) {
            Toast.makeText(this, "Companion: Not paired with Mac", Toast.LENGTH_SHORT).show()
            finish()
            overridePendingTransition(0, 0)
            return
        }

        executor.execute {
            try {
                val result = client.syncClipboardSmart()
                runOnUiThread {
                    Toast.makeText(this@SyncClipboardActivity, result, Toast.LENGTH_SHORT).show()
                    finish()
                    overridePendingTransition(0, 0)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    Toast.makeText(this@SyncClipboardActivity, "Sync failed: ${e.message}", Toast.LENGTH_SHORT).show()
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
