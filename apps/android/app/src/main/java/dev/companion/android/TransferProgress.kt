package dev.companion.android

data class TransferProgress(
    val id: String,
    val name: String,
    val direction: Direction,
    val transferredBytes: Long,
    val totalBytes: Long,
    val state: State,
    val error: String? = null,
    val timestamp: Long = System.currentTimeMillis()
) {
    enum class Direction { SEND, RECEIVE }
    enum class State { PREPARING, QUEUED, TRANSFERRING, VERIFYING, COMPLETED, FAILED }

    val percent: Int
        get() = if (totalBytes > 0) ((transferredBytes * 100) / totalBytes).toInt().coerceIn(0, 100) else if (state == State.COMPLETED) 100 else 0

    val formattedSize: String
        get() {
            val mb = totalBytes.toDouble() / 1_000_000
            return if (mb >= 1.0) String.format("%.1f MB", mb) else String.format("%d KB", totalBytes / 1000)
        }

    val formattedSummary: String
        get() {
            if (totalBytes <= 0) return String.format("%.1f MB prepared", transferredBytes.toDouble() / 1_000_000)
            val transferredMb = transferredBytes.toDouble() / 1_000_000
            val totalMb = totalBytes.toDouble() / 1_000_000
            return if (totalMb >= 1.0) {
                String.format("%.1f / %.1f MB", transferredMb, totalMb)
            } else {
                String.format("%d / %d KB", transferredBytes / 1000, totalBytes / 1000)
            }
        }
}
