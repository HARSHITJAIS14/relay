package dev.companion.android

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

data class MirroredNotification(
    val id: String,
    val packageName: String,
    val appName: String,
    val title: String,
    val text: String,
    val timestamp: Long,
    val canReply: Boolean
)

/**
 * Service that captures incoming notifications from messaging & social apps
 * and sends them to Mac. Also executes inline replies using RemoteInput.
 */
class RelayNotificationListenerService : NotificationListenerService() {
    companion object {
        private const val TAG = "RelayNotifService"

        @Volatile
        private var instance: RelayNotificationListenerService? = null

        fun getInstance(): RelayNotificationListenerService? = instance

        private val activeReplyActions = ConcurrentHashMap<String, ReplyTarget>()

        fun replyToNotification(context: Context, notificationKey: String, replyText: String): Boolean {
            val target = activeReplyActions[notificationKey] ?: return false
            return try {
                val intent = Intent()
                val bundle = Bundle().apply {
                    putCharSequence(target.remoteInput.resultKey, replyText)
                }
                RemoteInput.addResultsToIntent(arrayOf(target.remoteInput), intent, bundle)
                target.action.actionIntent.send(context, 0, intent)
                Log.i(TAG, "Dispatched inline reply to $notificationKey: $replyText")
                true
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send inline reply to $notificationKey", e)
                false
            }
        }

        fun isNotificationListenerEnabled(context: Context): Boolean {
            val enabledListeners = android.provider.Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            ) ?: ""
            return enabledListeners.contains(context.packageName)
        }

        /**
         * Finds the ongoing call notification and triggers the native Speaker/Earpiece action.
         */
        fun setSpeaker(on: Boolean): Boolean {
            val service = instance
            if (service == null) {
                Log.w(TAG, "RelayNotificationListenerService instance is null")
                return false
            }
            try {
                val notifs = service.activeNotifications ?: return false
                for (sbn in notifs) {
                    val notif = sbn.notification ?: continue
                    val isCall = notif.category == Notification.CATEGORY_CALL ||
                                 sbn.packageName.contains("dialer", ignoreCase = true) ||
                                 sbn.packageName.contains("telecom", ignoreCase = true) ||
                                 sbn.packageName.contains("phone", ignoreCase = true)
                    if (!isCall) continue

                    val actions = notif.actions ?: continue
                    // First pass: look for explicit match
                    for (action in actions) {
                        val title = action.title?.toString()?.trim() ?: continue
                        val lower = title.lowercase()
                        val matches = if (on) {
                            lower.contains("speaker") && !lower.contains("off")
                        } else {
                            lower.contains("earpiece") || lower.contains("speaker off") || lower.contains("phone") || lower.contains("handset")
                        }
                        if (matches) {
                            action.actionIntent.send()
                            Log.i(TAG, "Sent notification actionIntent for '$title' (${sbn.packageName}) to set speaker=$on")
                            return true
                        }
                    }
                    // Second pass: if looking to turn off, but only generic "Speaker" toggle exists
                    if (!on) {
                        for (action in actions) {
                            val title = action.title?.toString()?.trim() ?: continue
                            if (title.contains("speaker", ignoreCase = true)) {
                                action.actionIntent.send()
                                Log.i(TAG, "Sent notification actionIntent fallback for '$title' (${sbn.packageName}) to toggle speaker off")
                                return true
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to toggle speaker via notification action", e)
            }
            return false
        }

        /**
         * Finds the ongoing call notification and triggers the native Hang Up / End call action.
         */
        fun endCall(): Boolean {
            val service = instance ?: return false
            try {
                val notifs = service.activeNotifications ?: return false
                for (sbn in notifs) {
                    val notif = sbn.notification ?: continue
                    val isCall = notif.category == Notification.CATEGORY_CALL ||
                                 sbn.packageName.contains("dialer", ignoreCase = true) ||
                                 sbn.packageName.contains("phone", ignoreCase = true)
                    if (!isCall) continue

                    val actions = notif.actions ?: continue
                    for (action in actions) {
                        val title = action.title?.toString()?.trim()?.lowercase() ?: continue
                        if (title.contains("hang up") || title.contains("end") || title.contains("disconnect")) {
                            action.actionIntent.send()
                            Log.i(TAG, "Sent notification actionIntent for '$title' (${sbn.packageName}) to end call")
                            return true
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to end call via notification action", e)
            }
            return false
        }
    }

    data class ReplyTarget(val action: Notification.Action, val remoteInput: RemoteInput)

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.i(TAG, "Notification listener connected")
    }

    override fun onListenerDisconnected() {
        if (instance == this) instance = null
        super.onListenerDisconnected()
        Log.i(TAG, "Notification listener disconnected")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val notif = sbn.notification ?: return
        val pkg = sbn.packageName

        // Ignore our own notifications and ongoing system status bars
        if (pkg == packageName) return
        if (sbn.isOngoing && notif.category != Notification.CATEGORY_CALL) return

        val extras = notif.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim()
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim()
            ?: ""

        // Ignore completely empty notifications
        if (title.isEmpty() && text.isEmpty()) return

        // Resolve app name
        val pm = packageManager
        val appName = try {
            val appInfo = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            pkg
        }

        // Look for inline reply action
        var canReply = false
        val actions = notif.actions
        if (actions != null) {
            for (action in actions) {
                val inputs = action.remoteInputs
                if (inputs != null) {
                    val freeForm = inputs.firstOrNull { it.allowFreeFormInput }
                    if (freeForm != null) {
                        activeReplyActions[sbn.key] = ReplyTarget(action, freeForm)
                        canReply = true
                        break
                    }
                }
            }
        }

        val mirrored = MirroredNotification(
            id = sbn.key,
            packageName = pkg,
            appName = appName,
            title = title,
            text = text,
            timestamp = sbn.postTime,
            canReply = canReply
        )

        ConnectionCoordinator.getInstance(applicationContext).onNotificationPosted(mirrored)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        activeReplyActions.remove(sbn.key)
        ConnectionCoordinator.getInstance(applicationContext).onNotificationRemoved(sbn.key)
    }
}
