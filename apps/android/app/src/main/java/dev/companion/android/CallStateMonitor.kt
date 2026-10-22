package dev.companion.android

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log

class CallStateMonitor(private val context: Context) {
    companion object {
        private const val TAG = "RelayCallMonitor"
    }

    private val telephonyManager = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
    private val smsHelper = SmsManagerHelper(context)
    private var lastState = TelephonyManager.CALL_STATE_IDLE
    private var lastIncomingNumber: String? = null
    private var lastCallerName: String? = null

    private var telephonyCallback: Any? = null
    private var legacyListener: PhoneStateListener? = null

    fun start() {
        val tm = telephonyManager ?: return
        if (context.checkSelfPermission(android.Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            Log.d(TAG, "READ_PHONE_STATE not granted; call monitoring idle")
            return
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val callback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                    override fun onCallStateChanged(state: Int) {
                        handleStateChanged(state, null)
                    }
                }
                telephonyCallback = callback
                tm.registerTelephonyCallback(context.mainExecutor, callback)
            } else {
                @Suppress("DEPRECATION")
                val listener = object : PhoneStateListener() {
                    @Deprecated("Deprecated in Java")
                    override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                        handleStateChanged(state, phoneNumber)
                    }
                }
                legacyListener = listener
                @Suppress("DEPRECATION")
                tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            }
            Log.i(TAG, "Telephony call state monitoring started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start call state monitor", e)
        }
    }

    fun stop() {
        val tm = telephonyManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (telephonyCallback as? TelephonyCallback)?.let { tm.unregisterTelephonyCallback(it) }
                telephonyCallback = null
            } else {
                @Suppress("DEPRECATION")
                legacyListener?.let { tm.listen(it, PhoneStateListener.LISTEN_NONE) }
                legacyListener = null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop call state monitor", e)
        }
    }

    private fun handleStateChanged(state: Int, incomingNumber: String?) {
        val number = incomingNumber ?: lastIncomingNumber ?: "Unknown"
        val callerName = if (number != "Unknown") smsHelper.resolveContactName(number) else null

        when (state) {
            TelephonyManager.CALL_STATE_RINGING -> {
                lastIncomingNumber = incomingNumber
                lastCallerName = callerName
                Log.i(TAG, "Incoming call ringing: $number ($callerName)")
                ConnectionCoordinator.getInstance(context).onCallStateChanged(
                    state = "RINGING",
                    number = number,
                    callerName = callerName
                )
            }
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                Log.i(TAG, "Call off-hook (active)")
                ConnectionCoordinator.getInstance(context).onCallStateChanged(
                    state = "OFFHOOK",
                    number = lastIncomingNumber ?: number,
                    callerName = lastCallerName ?: callerName
                )
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                if (lastState == TelephonyManager.CALL_STATE_RINGING) {
                    Log.i(TAG, "Call missed from ${lastIncomingNumber ?: number}")
                    ConnectionCoordinator.getInstance(context).onCallStateChanged(
                        state = "MISSED",
                        number = lastIncomingNumber ?: number,
                        callerName = lastCallerName ?: callerName
                    )
                } else {
                    Log.i(TAG, "Call idle / ended")
                    ConnectionCoordinator.getInstance(context).onCallStateChanged(
                        state = "IDLE",
                        number = lastIncomingNumber ?: number,
                        callerName = lastCallerName ?: callerName
                    )
                }
                lastIncomingNumber = null
                lastCallerName = null
            }
        }
        lastState = state
    }
}
