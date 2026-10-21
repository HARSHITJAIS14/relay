package dev.companion.android

import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

data class SmsConversation(
    val threadId: Long,
    val address: String,
    val contactName: String?,
    val snippet: String,
    val date: Long,
    val unreadCount: Int
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("threadId", threadId)
        put("address", address ?: "")
        put("contactName", if (!contactName.isNullOrBlank()) contactName else (address ?: "Unknown"))
        put("snippet", snippet ?: "")
        put("date", date)
        put("unreadCount", unreadCount)
    }
}

data class SmsMessageItem(
    val id: Long,
    val threadId: Long,
    val address: String,
    val body: String,
    val date: Long,
    val type: Int // 1 = Inbox, 2 = Sent
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("threadId", threadId)
        put("address", address ?: "")
        put("body", body ?: "")
        put("date", date)
        put("type", type)
        put("isFromMe", type == Telephony.Sms.MESSAGE_TYPE_SENT)
    }
}

class SmsManagerHelper(private val context: Context) {
    companion object {
        private const val TAG = "SmsHelper"

        fun hasSmsPermissions(context: Context): Boolean {
            return context.checkSelfPermission(android.Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED &&
                   context.checkSelfPermission(android.Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun resolveContactName(phoneNumber: String): String? {
        val trimmed = phoneNumber.trim()
        if (trimmed.isEmpty()) return null
        if (!trimmed.any { it.isDigit() }) {
            return trimmed
        }
        if (context.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            return null
        }
        val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(trimmed))
        val projection = arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME)
        try {
            context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(ContactsContract.PhoneLookup.DISPLAY_NAME)
                    if (nameIdx >= 0) return cursor.getString(nameIdx)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error looking up contact for $trimmed: ${e.message}")
        }
        return null
    }

    fun getConversations(limit: Int = 40): List<SmsConversation> {
        if (context.checkSelfPermission(android.Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "READ_SMS permission not granted")
            return emptyList()
        }
        val list = mutableListOf<SmsConversation>()
        val seenThreads = mutableSetOf<Long>()
        val seenAddresses = mutableSetOf<String>()
        val uri = Telephony.Sms.CONTENT_URI
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.THREAD_ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.READ
        )

        try {
            context.contentResolver.query(
                uri,
                projection,
                null,
                null,
                "${Telephony.Sms.DATE} DESC"
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(Telephony.Sms._ID)
                val threadIdx = cursor.getColumnIndex(Telephony.Sms.THREAD_ID)
                val addressIdx = cursor.getColumnIndex(Telephony.Sms.ADDRESS)
                val bodyIdx = cursor.getColumnIndex(Telephony.Sms.BODY)
                val dateIdx = cursor.getColumnIndex(Telephony.Sms.DATE)
                val readIdx = cursor.getColumnIndex(Telephony.Sms.READ)

                while (cursor.moveToNext() && list.size < limit) {
                    val threadId = if (threadIdx >= 0) cursor.getLong(threadIdx) else 0L
                    val address = if (addressIdx >= 0) cursor.getString(addressIdx) ?: "" else ""
                    val normalizedAddr = address.trim().replace(" ", "").replace("-", "")

                    if (threadId > 0L) {
                        if (!seenThreads.add(threadId)) continue
                    } else if (normalizedAddr.isNotEmpty()) {
                        if (!seenAddresses.add(normalizedAddr)) continue
                    }

                    val body = if (bodyIdx >= 0) cursor.getString(bodyIdx) ?: "" else ""
                    val date = if (dateIdx >= 0) cursor.getLong(dateIdx) else 0L
                    val read = if (readIdx >= 0) cursor.getInt(readIdx) else 1
                    val contactName = resolveContactName(address)

                    list.add(
                        SmsConversation(
                            threadId = if (threadId > 0L) threadId else cursor.getLong(idIdx),
                            address = address,
                            contactName = contactName ?: address,
                            snippet = body,
                            date = date,
                            unreadCount = if (read == 0) 1 else 0
                        )
                    )
                }
            }
            Log.i(TAG, "Queried ${list.size} SMS conversations successfully")
        } catch (e: Exception) {
            Log.e(TAG, "Error querying SMS conversations", e)
        }
        return list
    }

    fun getThreadMessages(threadId: Long, limit: Int = 60): List<SmsMessageItem> {
        if (context.checkSelfPermission(android.Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED) {
            return emptyList()
        }
        val list = mutableListOf<SmsMessageItem>()
        val uri = Telephony.Sms.CONTENT_URI
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.THREAD_ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE
        )
        val selection = "${Telephony.Sms.THREAD_ID} = ?"
        val selectionArgs = arrayOf(threadId.toString())

        try {
            context.contentResolver.query(
                uri,
                projection,
                selection,
                selectionArgs,
                "${Telephony.Sms.DATE} ASC"
            )?.use { cursor ->
                val idIdx = cursor.getColumnIndex(Telephony.Sms._ID)
                val threadIdx = cursor.getColumnIndex(Telephony.Sms.THREAD_ID)
                val addressIdx = cursor.getColumnIndex(Telephony.Sms.ADDRESS)
                val bodyIdx = cursor.getColumnIndex(Telephony.Sms.BODY)
                val dateIdx = cursor.getColumnIndex(Telephony.Sms.DATE)
                val typeIdx = cursor.getColumnIndex(Telephony.Sms.TYPE)

                while (cursor.moveToNext() && list.size < limit) {
                    val id = if (idIdx >= 0) cursor.getLong(idIdx) else 0L
                    val address = if (addressIdx >= 0) cursor.getString(addressIdx) ?: "" else ""
                    val body = if (bodyIdx >= 0) cursor.getString(bodyIdx) ?: "" else ""
                    val date = if (dateIdx >= 0) cursor.getLong(dateIdx) else 0L
                    val type = if (typeIdx >= 0) cursor.getInt(typeIdx) else Telephony.Sms.MESSAGE_TYPE_INBOX

                    list.add(
                        SmsMessageItem(
                            id = id,
                            threadId = threadId,
                            address = address,
                            body = body,
                            date = date,
                            type = type
                        )
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error querying SMS messages for thread $threadId", e)
        }
        return list
    }

    fun sendSms(destinationAddress: String, text: String): Boolean {
        if (context.checkSelfPermission(android.Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("SEND_SMS permission not granted")
        }
        val trimmedDest = destinationAddress.trim()
        val trimmedText = text.trim()
        if (trimmedDest.isEmpty() || trimmedText.isEmpty()) return false

        val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }

        return try {
            val parts = smsManager.divideMessage(trimmedText)
            if (parts.size > 1) {
                smsManager.sendMultipartTextMessage(trimmedDest, null, parts, null, null)
            } else {
                smsManager.sendTextMessage(trimmedDest, null, trimmedText, null, null)
            }
            Log.i(TAG, "SMS successfully dispatched to $trimmedDest")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send SMS to $trimmedDest", e)
            false
        }
    }
}
