package dev.companion.android

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

enum class ConnectionState {
    NOT_PAIRED,
    LOOKING_FOR_MAC,
    CONNECTING,
    CONNECTED,
    NEEDS_ATTENTION
}

fun interface ConnectionStateListener {
    fun onConnectionStateChanged(state: ConnectionState, detail: String)
}

/**
 * Shared coordinator for managing connection state, automatic rediscovery,
 * backoff, and work serialization across MainActivity and CompanionSyncService.
 */
class ConnectionCoordinator private constructor(context: Context) {
    private val appContext = context.applicationContext
    val client = PeerClient(appContext)
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    private val listeners = CopyOnWriteArrayList<ConnectionStateListener>()
    private var currentState = ConnectionState.NOT_PAIRED
    private var currentDetail = "Starting…"

    private val isConnecting = AtomicBoolean(false)
    private val workQueue = java.util.concurrent.ConcurrentLinkedQueue<() -> Unit>()

    private lateinit var discoveryManager: RelayDiscoveryManager
    private val callMonitor = CallStateMonitor(appContext)

    companion object {
        private const val TAG = "ConnectionCoordinator"

        @Volatile
        private var instance: ConnectionCoordinator? = null

        fun getInstance(context: Context): ConnectionCoordinator {
            return instance ?: synchronized(this) {
                instance ?: ConnectionCoordinator(context).also { instance = it }
            }
        }
    }

    init {
        discoveryManager = RelayDiscoveryManager(appContext) { host, port ->
            executor.execute {
                if (client.hasInvitation && !isConnected()) {
                    Log.d(TAG, "Testing discovered candidate: $host:$port")
                    if (client.verifyAndSaveCandidate(host, port)) {
                        Log.i(TAG, "Successfully authenticated candidate Mac: $host:$port")
                        discoveryManager.stopDiscovery()
                        updateState(ConnectionState.CONNECTED, "Connected to Mac")
                        drainWorkQueue()
                    } else {
                        Log.w(TAG, "Candidate $host:$port rejected (untrusted or mTLS handshake failed)")
                    }
                }
            }
        }
        registerNetworkCallback()
        if (client.paired) {
            callMonitor.start()
        }
    }

    fun onNotificationPosted(notification: MirroredNotification) {
        if (isConnected()) {
            executor.execute {
                try {
                    client.sendNotification(notification)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send notification: ${e.message}")
                }
            }
        }
    }

    fun onNotificationRemoved(id: String) {
        if (isConnected()) {
            executor.execute {
                try {
                    client.sendNotificationDismiss(id)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send notification dismiss: ${e.message}")
                }
            }
        }
    }

    fun onIncomingSms(address: String, contactName: String?, body: String, timestamp: Long) {
        if (isConnected()) {
            executor.execute {
                try {
                    client.sendIncomingSms(address, contactName, body, timestamp)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send incoming SMS: ${e.message}")
                }
            }
        }
    }

    fun onCallStateChanged(state: String, number: String, callerName: String?) {
        if (isConnected()) {
            executor.execute {
                try {
                    client.sendCallState(state, number, callerName)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send call state: ${e.message}")
                }
            }
        }
    }

    fun isConnected(): Boolean = currentState == ConnectionState.CONNECTED

    fun getState(): ConnectionState = currentState
    fun getDetail(): String = currentDetail

    fun addListener(listener: ConnectionStateListener) {
        listeners.add(listener)
        listener.onConnectionStateChanged(currentState, currentDetail)
    }

    fun removeListener(listener: ConnectionStateListener) {
        listeners.remove(listener)
    }

    private fun updateState(newState: ConnectionState, detail: String) {
        currentState = newState
        currentDetail = detail
        handler.post {
            for (l in listeners) {
                l.onConnectionStateChanged(newState, detail)
            }
        }
    }

    private fun registerNetworkCallback() {
        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        try {
            cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    Log.d(TAG, "Network available, triggering connection refresh")
                    triggerRefresh()
                }

                override fun onLost(network: Network) {
                    Log.d(TAG, "Network lost")
                    if (client.paired) {
                        updateState(ConnectionState.LOOKING_FOR_MAC, "Network disconnected • Looking for Wi-Fi")
                    }
                }
            })
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register network callback", e)
        }
    }

    fun triggerRefresh() {
        if (!client.paired) {
            updateState(ConnectionState.NOT_PAIRED, "Pair your Mac to begin")
            return
        }
        if (!isConnecting.compareAndSet(false, true)) return

        executor.execute {
            try {
                updateState(ConnectionState.CONNECTING, "Connecting to Mac…")
                // 1. Try cached host first
                val cached = client.cachedHost
                if (cached.isNotBlank()) {
                    try {
                        val status = client.checkConnection()
                        updateState(ConnectionState.CONNECTED, status)
                        discoveryManager.stopDiscovery()
                        drainWorkQueue()
                        return@execute
                    } catch (e: Exception) {
                        Log.d(TAG, "Cached host $cached unreachable, starting discovery: ${e.message}")
                    }
                }

                // 2. Start service discovery
                updateState(ConnectionState.LOOKING_FOR_MAC, "Looking for Mac on local Wi-Fi…")
                discoveryManager.startDiscovery()

                // Wait up to 8 seconds for candidate discovery
                var elapsed = 0
                while (elapsed < 8000 && !isConnected() && isConnecting.get()) {
                    Thread.sleep(500)
                    elapsed += 500
                }

                if (!isConnected()) {
                    updateState(ConnectionState.NEEDS_ATTENTION, "Mac unreachable on local Wi-Fi")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error in connection refresh", e)
                updateState(ConnectionState.NEEDS_ATTENTION, "Connection error: ${e.message}")
            } finally {
                isConnecting.set(false)
            }
        }
    }

    fun queueWork(work: () -> Unit) {
        if (isConnected()) {
            executor.execute(work)
        } else {
            workQueue.offer(work)
            triggerRefresh()
        }
    }

    private fun drainWorkQueue() {
        while (!workQueue.isEmpty()) {
            val task = workQueue.poll() ?: break
            try {
                task.invoke()
            } catch (e: Exception) {
                Log.e(TAG, "Error executing queued work", e)
            }
        }
    }
}
