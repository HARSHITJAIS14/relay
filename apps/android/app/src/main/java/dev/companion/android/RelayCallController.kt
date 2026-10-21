package dev.companion.android

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.telecom.TelecomManager
import android.util.Log
import android.view.KeyEvent

/**
 * Handles incoming call control (Answer, Decline, Decline with SMS) and call placement (Dial)
 * dispatched from the paired Mac over Relay's encrypted connection.
 */
class RelayCallController(private val context: Context) {
    companion object {
        private const val TAG = "RelayCallController"

        fun hasCallPermissions(context: Context): Boolean {
            val answer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.checkSelfPermission(android.Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED
            } else true

            val call = context.checkSelfPermission(android.Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED
            return answer && call
        }
    }

    private val telecomManager = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager

    /**
     * Answers an incoming ringing call on the device.
     */
    fun answerCall(): Boolean {
        Log.i(TAG, "Request to answer ringing call received")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (context.checkSelfPermission(android.Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED) {
                try {
                    @Suppress("DEPRECATION")
                    telecomManager?.acceptRingingCall()
                    Log.i(TAG, "TelecomManager.acceptRingingCall() succeeded")
                    return true
                } catch (e: Exception) {
                    Log.e(TAG, "acceptRingingCall failed, trying media hook fallback", e)
                }
            } else {
                Log.w(TAG, "ANSWER_PHONE_CALLS permission not granted")
            }
        }

        // Fallback using headset hook media key
        return try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            val down = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_HEADSETHOOK)
            val up = KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_HEADSETHOOK)
            audioManager?.dispatchMediaKeyEvent(down)
            audioManager?.dispatchMediaKeyEvent(up)
            Log.i(TAG, "Dispatched KEYCODE_HEADSETHOOK to answer call")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Media key answer fallback failed", e)
            false
        }
    }

    /**
     * Rejects or ends an active/incoming call on the device.
     */
    fun endCall(): Boolean {
        Log.i(TAG, "Request to end/reject call received")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            if (context.checkSelfPermission(android.Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED) {
                try {
                    val ended = telecomManager?.endCall() ?: false
                    Log.i(TAG, "TelecomManager.endCall() returned $ended")
                    return ended
                } catch (e: Exception) {
                    Log.e(TAG, "TelecomManager.endCall() failed", e)
                }
            } else {
                Log.w(TAG, "ANSWER_PHONE_CALLS permission not granted for endCall")
            }
        }

        // Secondary fallback
        return try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            val down = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_HEADSETHOOK)
            val up = KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_HEADSETHOOK)
            audioManager?.dispatchMediaKeyEvent(down)
            audioManager?.dispatchMediaKeyEvent(up)
            true
        } catch (e: Exception) {
            Log.e(TAG, "End call fallback failed", e)
            false
        }
    }

    /**
     * Dials a destination phone number.
     * Uses ACTION_CALL if CALL_PHONE permission is granted, otherwise ACTION_DIAL.
     */
    fun dialNumber(number: String): Boolean {
        val trimmed = number.trim()
        if (trimmed.isEmpty()) return false
        Log.i(TAG, "Dialing number: $trimmed")

        return try {
            val uri = Uri.parse("tel:${Uri.encode(trimmed)}")
            val hasCallPermission = context.checkSelfPermission(android.Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED

            val intent = if (hasCallPermission) {
                Intent(Intent.ACTION_CALL, uri)
            } else {
                Intent(Intent.ACTION_DIAL, uri)
            }.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }

            context.startActivity(intent)
            Log.i(TAG, "Started dial intent (direct call: $hasCallPermission)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to dial number $trimmed", e)
            false
        }
    }

    /**
     * Sends an instant SMS decline reply to the caller and terminates the call.
     */
    fun declineWithSms(destinationAddress: String, message: String): Boolean {
        Log.i(TAG, "Declining call from $destinationAddress with quick SMS: $message")
        val smsHelper = SmsManagerHelper(context)
        val smsSent = try {
            smsHelper.sendSms(destinationAddress, message)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to send quick SMS", e)
            false
        }

        // Terminate call regardless of SMS status
        val callEnded = endCall()
        return callEnded || smsSent
    }
}
