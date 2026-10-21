package dev.companion.android

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Discovers Relay Mac instances via local network DNS-SD (_relay._tcp).
 * Resolves candidate host IPs safely and notifies the coordinator.
 */
class RelayDiscoveryManager(
    private val context: Context,
    private val onCandidateResolved: (host: String, port: Int) -> Unit
) {
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val isDiscovering = AtomicBoolean(false)
    private val resolveQueue = ConcurrentLinkedQueue<NsdServiceInfo>()
    private val isResolving = AtomicBoolean(false)
    private val handler = Handler(Looper.getMainLooper())

    companion object {
        private const val TAG = "RelayDiscovery"
        const val SERVICE_TYPE = "_relay._tcp."
    }

    private val discoveryListener = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(regType: String) {
            Log.d(TAG, "Relay service discovery started: $regType")
            isDiscovering.set(true)
        }

        override fun onServiceFound(serviceInfo: NsdServiceInfo) {
            Log.d(TAG, "Service candidate found: ${serviceInfo.serviceName}")
            if (serviceInfo.serviceType.contains("_relay")) {
                resolveQueue.offer(serviceInfo)
                processNextResolve()
            }
        }

        override fun onServiceLost(serviceInfo: NsdServiceInfo) {
            Log.d(TAG, "Service candidate lost: ${serviceInfo.serviceName}")
        }

        override fun onDiscoveryStopped(serviceType: String) {
            Log.d(TAG, "Relay service discovery stopped")
            isDiscovering.set(false)
        }

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Start discovery failed: $errorCode")
            isDiscovering.set(false)
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            Log.e(TAG, "Stop discovery failed: $errorCode")
            isDiscovering.set(false)
        }
    }

    @Synchronized
    fun startDiscovery() {
        if (nsdManager == null) return
        if (isDiscovering.compareAndSet(false, true)) {
            try {
                nsdManager.discoverServices(
                    "_relay._tcp",
                    NsdManager.PROTOCOL_DNS_SD,
                    discoveryListener
                )
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start service discovery", e)
                isDiscovering.set(false)
            }
        }
    }

    @Synchronized
    fun stopDiscovery() {
        if (nsdManager == null) return
        if (isDiscovering.compareAndSet(true, false)) {
            try {
                nsdManager.stopServiceDiscovery(discoveryListener)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop service discovery", e)
            }
        }
        resolveQueue.clear()
        isResolving.set(false)
    }

    private fun processNextResolve() {
        if (nsdManager == null) return
        if (!isResolving.compareAndSet(false, true)) return

        val candidate = resolveQueue.poll()
        if (candidate == null) {
            isResolving.set(false)
            return
        }

        try {
            nsdManager.resolveService(candidate, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    Log.w(TAG, "Resolve failed for ${serviceInfo.serviceName}: $errorCode")
                    isResolving.set(false)
                    handler.postDelayed({ processNextResolve() }, 100)
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    val host = serviceInfo.host?.hostAddress
                    val port = serviceInfo.port
                    Log.d(TAG, "Resolved Relay candidate: $host:$port")
                    if (!host.isNullOrBlank() && port in 1..65535) {
                        onCandidateResolved(host, port)
                    }
                    isResolving.set(false)
                    handler.postDelayed({ processNextResolve() }, 100)
                }
            })
        } catch (e: Exception) {
            Log.e(TAG, "Exception initiating resolve", e)
            isResolving.set(false)
            handler.postDelayed({ processNextResolve() }, 100)
        }
    }
}
