package dev.companion.android

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.LinearLayout
import android.widget.Toast
import java.util.concurrent.Executors

/**
 * Handles incoming system share intents (ACTION_SEND and ACTION_SEND_MULTIPLE)
 * for files, photos, PDFs, and links/text.
 */
class ShareActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var statusText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val spacing = (20 * resources.displayMetrics.density).toInt()
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(spacing, spacing, spacing, spacing)
            gravity = android.view.Gravity.CENTER
        }
        val progress = ProgressBar(this).apply {
            isIndeterminate = true
            layout.addView(this)
        }
        statusText = TextView(this).apply {
            text = "Sending to Mac…"
            textSize = 16f
            setPadding(0, spacing, 0, 0)
            gravity = android.view.Gravity.CENTER
            layout.addView(this)
        }
        setContentView(layout)

        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent) {
        val action = intent.action
        val type = intent.type

        executor.execute {
            try {
                val client = PeerClient(applicationContext)
                if (!client.paired) {
                    notifyAndFinish("Open Companion and pair with your Mac first.")
                    return@execute
                }

                when (action) {
                    Intent.ACTION_SEND -> {
                        val streamUri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                            ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri
                        val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
                            ?: intent.clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()

                        if (streamUri != null) {
                            updateStatus("Staging file…")
                            client.stage(streamUri)
                            updateStatus("Sending to Mac…")
                            val result = client.sendPending() ?: "File queued"
                            notifyAndFinish(result)
                        } else if (!sharedText.isNullOrBlank()) {
                            updateStatus("Sending to Mac…")
                            val result = client.sendText(sharedText)
                            notifyAndFinish(result)
                        } else {
                            notifyAndFinish("Nothing to share")
                        }
                    }
                    Intent.ACTION_SEND_MULTIPLE -> {
                        val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                        if (uris.isNullOrEmpty()) {
                            notifyAndFinish("No files to share")
                            return@execute
                        }
                        updateStatus("Staging ${uris.size} files…")
                        for (uri in uris) {
                            client.stage(uri)
                        }
                        updateStatus("Sending to Mac…")
                        var sentCount = 0
                        while (true) {
                            val res = client.sendPending() ?: break
                            sentCount++
                            updateStatus("Sent $sentCount of ${uris.size} files…")
                        }
                        notifyAndFinish("Sent $sentCount files to Mac")
                    }
                    else -> notifyAndFinish("Unsupported share action")
                }
            } catch (e: Exception) {
                notifyAndFinish("Queued for Mac: ${e.message ?: "Will retry"}")
            }
        }
    }

    private fun updateStatus(msg: String) {
        handler.post {
            if (!isFinishing && !isDestroyed) {
                statusText.text = msg
            }
        }
    }

    private fun notifyAndFinish(msg: String) {
        handler.post {
            Toast.makeText(applicationContext, msg, Toast.LENGTH_LONG).show()
            finish()
        }
    }

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }
}
