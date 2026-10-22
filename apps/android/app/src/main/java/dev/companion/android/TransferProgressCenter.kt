package dev.companion.android

import java.util.concurrent.CopyOnWriteArrayList

/** Replays transfer progress to the dashboard and background notification independently. */
object TransferProgressCenter {
    private val listeners = CopyOnWriteArrayList<(TransferProgress) -> Unit>()
    @Volatile var latest: TransferProgress? = null
        private set

    fun publish(progress: TransferProgress) {
        latest = progress
        listeners.forEach { it(progress) }
    }

    fun addListener(listener: (TransferProgress) -> Unit) {
        listeners.add(listener)
        latest?.let(listener)
    }

    fun removeListener(listener: (TransferProgress) -> Unit) {
        listeners.remove(listener)
    }
}
