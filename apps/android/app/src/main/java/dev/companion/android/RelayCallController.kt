package dev.companion.android

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
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
     * Answers an incoming ringing call on the device, optionally enabling speakerphone.
     */
    fun answerCall(useSpeakerphone: Boolean = false): Boolean {
        Log.i(TAG, "Request to answer ringing call received (speakerphone=$useSpeakerphone)")
        var success = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (context.checkSelfPermission(android.Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED) {
                try {
                    @Suppress("DEPRECATION")
                    telecomManager?.acceptRingingCall()
                    Log.i(TAG, "TelecomManager.acceptRingingCall() succeeded")
                    success = true
                } catch (e: Exception) {
                    Log.e(TAG, "acceptRingingCall failed, trying media hook fallback", e)
                }
            } else {
                Log.w(TAG, "ANSWER_PHONE_CALLS permission not granted")
            }
        }

        if (!success) {
            // Fallback using headset hook media key
            try {
                val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                val down = KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_HEADSETHOOK)
                val up = KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_HEADSETHOOK)
                audioManager?.dispatchMediaKeyEvent(down)
                audioManager?.dispatchMediaKeyEvent(up)
                Log.i(TAG, "Dispatched KEYCODE_HEADSETHOOK to answer call")
                success = true
            } catch (e: Exception) {
                Log.e(TAG, "Media key answer fallback failed", e)
            }
        }

        if (success && useSpeakerphone) {
            setSpeakerphone(true)
        }
        return success
    }

    /**
     * Toggles speakerphone mode on/off on the device.
     */
    fun setSpeakerphone(on: Boolean) {
        try {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
            Log.i(TAG, "Request to toggle speakerphone to $on (SDK=${Build.VERSION.SDK_INT})")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (on) {
                    audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                    val speaker = audioManager.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    }
                    if (speaker != null) {
                        val success = audioManager.setCommunicationDevice(speaker)
                        Log.i(TAG, "audioManager.setCommunicationDevice(SPEAKER) returned $success")
                    } else {
                        Log.w(TAG, "TYPE_BUILTIN_SPEAKER not found in availableCommunicationDevices")
                        @Suppress("DEPRECATION")
                        audioManager.isSpeakerphoneOn = true
                    }
                } else {
                    audioManager.clearCommunicationDevice()
                    audioManager.mode = AudioManager.MODE_NORMAL
                    @Suppress("DEPRECATION")
                    audioManager.isSpeakerphoneOn = false
                    Log.i(TAG, "audioManager.clearCommunicationDevice() executed")
                }
            } else {
                @Suppress("DEPRECATION")
                audioManager.mode = if (on) AudioManager.MODE_IN_CALL else AudioManager.MODE_NORMAL
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = on
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to toggle speakerphone", e)
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
     * Uses TelecomManager.placeCall when available (bypasses Android 14+ background launch limits
     * and directly commands Telecom to place the call and display the in-call UI), falling back to
     * ACTION_CALL / ACTION_DIAL.
     */
    fun dialNumber(number: String): Boolean {
        val trimmed = number.trim()
        if (trimmed.isEmpty()) return false
        Log.i(TAG, "Dialing number: $trimmed")

        // 1. Wake the screen if locked/sleeping so the in-call UI is immediately presented
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            val wakeLock = pm?.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
                "dev.companion.android:CallWakeLock"
            )
            wakeLock?.acquire(3000)
        } catch (e: Exception) {
            Log.w(TAG, "WakeLock acquisition failed", e)
        }

        val uri = Uri.parse("tel:${Uri.encode(trimmed)}")
        val hasCallPermission = context.checkSelfPermission(android.Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED

        // 2. Direct TelecomManager call placement (system service, displays InCallActivity without BAL blocks)
        if (hasCallPermission && telecomManager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                val extras = Bundle().apply {
                    val defaultAccount = telecomManager.getDefaultOutgoingPhoneAccount(uri.scheme)
                    if (defaultAccount != null) {
                        putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, defaultAccount)
                    }
                }
                Log.i(TAG, "Placing direct call via TelecomManager.placeCall to $trimmed")
                telecomManager.placeCall(uri, extras)
                return true
            } catch (e: Exception) {
                Log.w(TAG, "TelecomManager.placeCall threw exception, attempting Intent fallback", e)
            }
        }

        // 3. Fallback Intent
        return try {
            val intent = if (hasCallPermission) {
                Intent(Intent.ACTION_CALL, uri)
            } else {
                Intent(Intent.ACTION_DIAL, uri)
            }.apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
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
