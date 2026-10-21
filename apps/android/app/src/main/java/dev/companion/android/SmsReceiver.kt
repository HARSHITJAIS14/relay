package dev.companion.android

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

class SmsReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "RelaySmsReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return

        try {
            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            if (messages.isNullOrEmpty()) return

            val sender = messages[0].displayOriginatingAddress ?: ""
            val body = messages.joinToString("") { it.displayMessageBody ?: "" }
            val timestamp = messages[0].timestampMillis

            val helper = SmsManagerHelper(context)
            val contactName = helper.resolveContactName(sender)

            Log.i(TAG, "Incoming SMS from $sender ($contactName): ${body.take(20)}")
            ConnectionCoordinator.getInstance(context).onIncomingSms(sender, contactName, body, timestamp)
        } catch (e: Exception) {
            Log.e(TAG, "Error handling incoming SMS broadcast", e)
        }
    }
}
