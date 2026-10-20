package dev.companion.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.widget.Toast
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class CompanionSyncService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(true)
    private lateinit var client: PeerClient

    companion object {
        const val ACTION_COPY_TO_MAC = "dev.companion.android.action.COPY_TO_MAC"
        private const val CHANNEL_ID = "companion_sync_channel"
        private const val CAPTURE_CHANNEL_ID = "companion_capture_channel"
        private const val NOTIFICATION_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, CompanionSyncService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CompanionSyncService::class.java))
        }
    }

    override fun onCreate() {
        super.onCreate()
        client = PeerClient(applicationContext)
        createNotificationChannel()
        val notification = buildNotification()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            try {
                startForeground(NOTIFICATION_ID, notification)
            } catch (ignored: Exception) {}
        }

        startSyncLoop()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_COPY_TO_MAC) {
            handleCopyToMac()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        running.set(false)
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun handleCopyToMac() {
        executor.execute {
            try {
                val text = client.getLocalClipboardText()
                if (text.isNullOrBlank()) {
                    handler.post { Toast.makeText(this, "Clipboard is empty", Toast.LENGTH_SHORT).show() }
                    return@execute
                }
                client.syncClipboardToMac(text)
                val preview = if (text.length > 25) text.take(25) + "…" else text
                handler.post {
                    Toast.makeText(this, "Copied to Mac: $preview", Toast.LENGTH_SHORT).show()
                }
            } catch (e: Exception) {
                handler.post {
                    Toast.makeText(this, "Failed to copy: ${e.message}", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    private var lastSeenCaptureId: String? = null

    private fun startSyncLoop() {
        executor.execute {
            var delayMs = 2000L
            while (running.get()) {
                try {
                    if (client.paired) {
                        client.pollRemoteClipboard(applyImmediately = client.autoApplyMacClipboard)
                        client.receiveNext()
                        client.receiveNextInboxItem()
                        client.sendPending()
                        val captureReq = client.pollCaptureRequest()
                        if (captureReq != null) {
                            showCaptureNotification(captureReq.id, captureReq.mode)
                        }
                        delayMs = 2000L
                    } else {
                        delayMs = 5000L
                    }
                } catch (e: Exception) {
                    // Connection error or Mac temporarily unreachable; back off
                    delayMs = 5000L
                }

                try {
                    Thread.sleep(delayMs)
                } catch (e: InterruptedException) {
                    break
                }
            }
        }
    }

    private fun showCaptureNotification(id: String, mode: String) {
        if (id == lastSeenCaptureId) return
        lastSeenCaptureId = id
        val title = if (mode == "scan") "Mac requested a Document Scan" else "Mac requested a Photo"
        val text = "Tap to open camera and send directly to Mac"

        val captureIntent = Intent(this, CaptureActivity::class.java).apply {
            putExtra(CaptureActivity.EXTRA_MODE, mode)
            putExtra(CaptureActivity.EXTRA_CAPTURE_ID, id)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pending = PendingIntent.getActivity(
            this,
            105,
            captureIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CAPTURE_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val notification = builder
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()

        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(2001, notification)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val syncChannel = NotificationChannel(
                CHANNEL_ID,
                "Companion Continuous Sync",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps clipboard and file transfers active with your Mac."
                setShowBadge(false)
            }
            val captureChannel = NotificationChannel(
                CAPTURE_CHANNEL_ID,
                "Companion Capture Requests",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifies when Mac requests a photo or document scan."
                setShowBadge(true)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(syncChannel)
            manager.createNotificationChannel(captureChannel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingLaunch = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val syncIntent = Intent(this, SyncClipboardActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val pendingSync = PendingIntent.getActivity(
            this,
            3,
            syncIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val getFromMacIntent = Intent(this, GetMacClipboardActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val pendingGetFromMac = PendingIntent.getActivity(
            this,
            2,
            getFromMacIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val copyIntent = Intent(this, CopyNotificationActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val pendingCopy = PendingIntent.getActivity(
            this,
            1,
            copyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        builder.setContentTitle("Relay")
            .setContentText("Connected to Mac • Tap 'Sync Clip' to synchronize")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentIntent(pendingLaunch)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "Sync Clip",
                    pendingSync
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    null,
                    "Get from Mac",
                    pendingGetFromMac
                ).build()
            )
            .addAction(
                Notification.Action.Builder(
                    null,
                    "Copy to Mac",
                    pendingCopy
                ).build()
            )
            .setOngoing(true)

        return builder.build()
    }
}
