package dev.companion.android

import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.util.Log

/**
 * Non-UI InCallService that binds to Android Telecom to provide direct,
 * native call audio routing (Speakerphone, Earpiece) and call management.
 */
class RelayInCallService : InCallService() {
    companion object {
        private const val TAG = "RelayInCallService"
        @Volatile
        private var instance: RelayInCallService? = null

        fun hasActiveService(): Boolean = instance != null

        fun setSpeaker(on: Boolean): Boolean {
            val service = instance
            if (service == null) {
                Log.d(TAG, "No active RelayInCallService instance available")
                return false
            }
            return try {
                @Suppress("DEPRECATION")
                val route = if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_EARPIECE
                @Suppress("DEPRECATION")
                service.setAudioRoute(route)
                Log.i(TAG, "setAudioRoute($route) called on Telecom InCallService (on=$on)")
                true
            } catch (e: Exception) {
                Log.e(TAG, "Failed to set audio route via InCallService", e)
                false
            }
        }

        fun endCall(): Boolean {
            val service = instance ?: return false
            return try {
                val active = service.calls.firstOrNull()
                if (active != null) {
                    active.disconnect()
                    Log.i(TAG, "active.disconnect() called on active call")
                    true
                } else false
            } catch (e: Exception) {
                Log.e(TAG, "Failed to disconnect call via InCallService", e)
                false
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.i(TAG, "RelayInCallService created")
    }

    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        instance = this
        Log.i(TAG, "Telecom call added: $call, state=${call.state}")
    }

    override fun onCallRemoved(call: Call) {
        super.onCallRemoved(call)
        Log.i(TAG, "Telecom call removed: $call")
        if (calls.isEmpty()) {
            instance = null
        }
    }

    override fun onDestroy() {
        if (instance == this) {
            instance = null
        }
        super.onDestroy()
    }
}
