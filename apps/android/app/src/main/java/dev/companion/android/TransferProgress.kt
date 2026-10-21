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
    enum class State { PREPARING, TRANSFERRING, VERIFYING, COMPLETED, FAILED }

    val percent: Int
        get() = if (totalBytes > 0) ((transferredBytes * 100) / totalBytes).toInt().coerceIn(0, 100) else 0

    val formattedSize: String
        get() {
            val mb = totalBytes.toDouble() / (1024 * 1024)
            return if (mb >= 1.0) String.format("%.1f MB", mb) else String.format("%d KB", totalBytes / 1024)
        }

    val formattedSummary: String
        get() {
            val transferredMb = transferredBytes.toDouble() / (1024 * 1024)
            val totalMb = totalBytes.toDouble() / (1024 * 1024)
            return if (totalMb >= 1.0) {
                String.format("%.1f / %.1f MB", transferredMb, totalMb)
            } else {
                String.format("%d / %d KB", transferredBytes / 1024, totalBytes / 1024)
            }
        }
}
