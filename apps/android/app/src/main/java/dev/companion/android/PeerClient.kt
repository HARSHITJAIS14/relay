package dev.companion.android

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import org.json.JSONObject
import java.io.*
import java.net.InetSocketAddress
import java.net.Socket
import java.security.*
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.UUID
import javax.net.ssl.*
import javax.security.auth.x500.X500Principal

private const val TAG = "PeerClient"
private const val IDENTITY_ALIAS = "companion-phone-v2"
private const val MAX_FILE = 100L * 1024 * 1024
internal fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
private fun json(vararg entries: Pair<String, Any>) = JSONObject().put("version", 1).apply {
    entries.forEach { (key, value) -> put(key, value) }
}

/** Serialized by the caller. All methods perform blocking IO and run off the UI thread. */
class PeerClient(private val context: Context) {
    private val preferences = context.getSharedPreferences("companion-peer-v1", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val paired get() = preferences.getBoolean("paired", false)
    val hasInvitation get() = preferences.contains("pin")
    val pairingCode get() = preferences.getString("code", "") ?: ""
    val host get() = preferences.getString("host", "") ?: ""
    private val pin get() = preferences.getString("pin", "") ?: ""
    var onTransferProgress: ((TransferProgress) -> Unit)? = null

    private fun emitProgress(progress: TransferProgress) {
        onTransferProgress?.invoke(progress)
    }

    var lastSyncSummary: String?
        get() = preferences.getString("last_sync_summary", null)
        set(value) { preferences.edit().putString("last_sync_summary", value).apply() }

    init {
        if (!keyStore.containsAlias(IDENTITY_ALIAS)) {
            val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
            generator.initialize(
                KeyGenParameterSpec.Builder(IDENTITY_ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(
                        KeyProperties.DIGEST_NONE,
                        KeyProperties.DIGEST_SHA256,
                        KeyProperties.DIGEST_SHA384,
                        KeyProperties.DIGEST_SHA512
                    )
                    .setCertificateSubject(X500Principal("CN=Companion Phone"))
                    .setCertificateSerialNumber(java.math.BigInteger.ONE)
                    .setCertificateNotBefore(Date(System.currentTimeMillis() - 86400000))
                    .setCertificateNotAfter(Date(System.currentTimeMillis() + 10L * 365 * 86400000))
                    .build()
            )
            generator.generateKeyPair()
        }
    }

    fun beginPairing(invitation: String): String {
        check(!paired) { "Forget the current Mac before pairing another." }
        val uri = Uri.parse(invitation.trim())
        require(uri.scheme == "companion" && uri.path == "/pair" && !uri.host.isNullOrEmpty())
        val fingerprint = uri.getQueryParameter("pin") ?: error("Missing Mac fingerprint")
        val token = uri.getQueryParameter("token") ?: error("Missing invitation token")
        require(fingerprint.matches(Regex("[0-9a-f]{64}")) && token.length in 40..64 && uri.port in 1..65535) {
            "Invalid invitation"
        }
        check(preferences.edit().putString("host", uri.host).putInt("port", uri.port)
            .putString("pin", fingerprint).putString("token", token).putBoolean("paired", false).commit())
        return pollPairing()
    }

    fun pollPairing(): String {
        check(hasInvitation)
        val token = preferences.getString("token", "")!!
        return connect().use { channel ->
            channel.send(json("type" to "pair.request", "token" to token, "name" to android.os.Build.MODEL))
            val response = channel.receive()
            when (response.getString("type")) {
                "pair.complete" -> {
                    check(preferences.edit().putBoolean("paired", true).remove("token").remove("code").commit())
                    "Paired with Mac"
                }
                "pair.pending" -> {
                    val ownFingerprint = sha256(keyStore.getCertificate(IDENTITY_ALIAS).encoded)
                    val expected = sha256("$pin:$ownFingerprint:$token".toByteArray()).take(8).uppercase()
                    check(response.getString("code") == expected) { "Pairing verification code does not match" }
                    check(preferences.edit().putString("code", expected).commit())
                    "Check code $expected on Mac, then approve pairing there."
                }
                else -> error("Unexpected pairing response")
            }
        }
    }

    fun forget() { check(preferences.edit().clear().commit()) }

    fun checkConnection(): String = connect().use {
        check(paired)
        it.send(json("type" to "session.check"))
        check(it.receive().getString("type") == "session.ready")
        "Connected to Mac"
    }

    fun stage(uri: Uri): File {
        check(paired)
        var name = "Shared file"
        context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) name = it.getString(0) ?: name
        }
        name = name.replace("/", "_").replace("\\", "_").replace("\u0000", "_")
        require(name.toByteArray().size <= 180) { "Filename is too long" }
        val id = UUID.randomUUID().toString()
        val directory = File(context.filesDir, "outbox/$pin").apply { mkdirs() }
        val data = File(directory, "$id.data")
        try {
            var size = 0L
            val hash = MessageDigest.getInstance("SHA-256")
            context.contentResolver.openInputStream(uri)!!.use { input ->
                FileOutputStream(data).use { output ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        size += count
                        require(size <= MAX_FILE) { "Development build supports files up to 100 MiB" }
                        hash.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            val manifest = File(directory, "$id.json")
            val offer = json("type" to "file.offer", "id" to id, "name" to name, "size" to size,
                "sha256" to hash.digest().joinToString("") { "%02x".format(it) })
            FileOutputStream(manifest).use { it.write(offer.toString().toByteArray()); it.fd.sync() }
            return manifest
        } catch (error: Exception) {
            data.delete()
            throw error
        }
    }

    fun stageFile(file: File, displayName: String = file.name): File {
        check(paired)
        var name = displayName.replace("/", "_").replace("\\", "_").replace("\u0000", "_")
        require(name.toByteArray().size <= 180) { "Filename is too long" }
        val id = UUID.randomUUID().toString()
        val directory = File(context.filesDir, "outbox/$pin").apply { mkdirs() }
        val data = File(directory, "$id.data")
        try {
            var size = 0L
            val hash = MessageDigest.getInstance("SHA-256")
            FileInputStream(file).use { input ->
                FileOutputStream(data).use { output ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        size += count
                        require(size <= MAX_FILE) { "File exceeds 100 MiB limit" }
                        hash.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            val manifest = File(directory, "$id.json")
            val offer = json("type" to "file.offer", "id" to id, "name" to name, "size" to size,
                "sha256" to hash.digest().joinToString("") { "%02x".format(it) })
            FileOutputStream(manifest).use { it.write(offer.toString().toByteArray()); it.fd.sync() }
            return manifest
        } catch (error: Exception) {
            data.delete()
            throw error
        }
    }

    fun sendPending(): String? {
        check(paired)
        val manifest = File(context.filesDir, "outbox/$pin").listFiles()?.filter { it.extension == "json" }?.sorted()?.firstOrNull()
            ?: return null
        val offer = JSONObject(manifest.readText())
        val id = offer.getString("id")
        val name = offer.getString("name")
        val size = offer.getLong("size")
        val file = File(manifest.parentFile, "$id.data")

        emitProgress(TransferProgress(id, name, TransferProgress.Direction.SEND, 0L, size, TransferProgress.State.PREPARING))

        try {
            connect().use { channel ->
                channel.send(offer)
                var response = channel.receive()
                if (response.getString("type") == "file.ready") {
                    val resumeOffset = response.optLong("size", 0L)
                    emitProgress(TransferProgress(id, name, TransferProgress.Direction.SEND, resumeOffset, size, TransferProgress.State.TRANSFERRING))
                    FileInputStream(file).use { input ->
                        if (resumeOffset > 0 && resumeOffset < size) {
                            var skipped = 0L
                            while (skipped < resumeOffset) {
                                val count = input.skip(resumeOffset - skipped)
                                if (count <= 0) break
                                skipped += count
                            }
                        }
                        val buffer = ByteArray(65536)
                        var transferred = resumeOffset
                        var lastEmit = System.currentTimeMillis()
                        while (true) {
                            val read = input.read(buffer)
                            if (read <= 0) break
                            channel.output.write(buffer, 0, read)
                            transferred += read
                            val now = System.currentTimeMillis()
                            if (now - lastEmit >= 200 || transferred == size) {
                                emitProgress(TransferProgress(id, name, TransferProgress.Direction.SEND, transferred, size, TransferProgress.State.TRANSFERRING))
                                lastEmit = now
                            }
                        }
                    }
                    channel.output.flush()
                    response = channel.receive()
                }
                check(response.getString("type") == "file.saved" &&
                    response.getString("id") == id &&
                    response.getString("sha256") == offer.getString("sha256")) { "Mac did not confirm a verified save" }
            }
            check(manifest.delete()) { "Sent, but could not clear local queue" }
            file.delete()
            emitProgress(TransferProgress(id, name, TransferProgress.Direction.SEND, size, size, TransferProgress.State.COMPLETED))
            return "Sent $name"
        } catch (e: Exception) {
            emitProgress(TransferProgress(id, name, TransferProgress.Direction.SEND, 0L, size, TransferProgress.State.FAILED, e.message))
            throw e
        }
    }

    fun sendText(text: String): String {
        check(paired)
        val trimmed = text.trim()
        require(trimmed.isNotEmpty()) { "Cannot send empty text" }
        require(trimmed.toByteArray().size <= 256 * 1024) { "Text exceeds 256 KiB limit" }
        val id = UUID.randomUUID().toString()
        connect().use { channel ->
            channel.send(json("type" to "inbox.item", "id" to id, "text" to trimmed))
            val response = channel.receive()
            check(response.getString("type") == "inbox.receipt" && response.getString("id") == id) {
                "Mac did not confirm receipt"
            }
        }
        return "Sent to Mac"
    }

    @Volatile
    private var lastAppliedRemoteClipboard: String? = null
    @Volatile
    private var lastSentLocalClipboard: String? = null

    var lastSeenClipboardSeq: Int
        get() = preferences.getInt("clipboard_seq", 0)
        set(value) { preferences.edit().putInt("clipboard_seq", value).apply() }

    fun getLocalClipboardTimestamp(): Long {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        return clipboard.primaryClipDescription?.timestamp ?: 0L
    }

    fun syncClipboardToMac(text: String, timestamp: Long = System.currentTimeMillis()): String {
        check(paired)
        val trimmed = text.trim()
        require(trimmed.isNotEmpty()) { "Cannot send empty clipboard" }
        require(trimmed.toByteArray().size <= 256 * 1024) { "Clipboard text exceeds 256 KiB limit" }
        lastSentLocalClipboard = trimmed
        connect().use { channel ->
            channel.send(json("type" to "clipboard.sync", "text" to trimmed, "timestamp" to timestamp))
            val response = channel.receive()
            check(response.getString("type") == "clipboard.receipt") {
                "Mac did not confirm clipboard receipt"
            }
            val newSeq = response.optInt("seq", 0)
            if (newSeq > 0) {
                lastSeenClipboardSeq = newSeq
            }
        }
        return "Copied to Mac clipboard"
    }

    var autoApplyMacClipboard: Boolean
        get() = preferences.getBoolean("auto_apply_mac_clipboard", false)
        set(value) { preferences.edit().putBoolean("auto_apply_mac_clipboard", value).apply() }

    var latestKnownMacClipboard: String?
        get() = preferences.getString("latest_mac_clipboard", null)
        set(value) { preferences.edit().putString("latest_mac_clipboard", value).apply() }

    data class RemoteClipboardInfo(val text: String, val seq: Int, val timestamp: Long)

    fun fetchMacClipboard(force: Boolean = true): RemoteClipboardInfo? {
        if (!paired) return null
        return connect().use { channel ->
            channel.send(json("type" to "clipboard.poll", "seq" to (if (force) 0 else lastSeenClipboardSeq)))
            val response = channel.receive()
            if (response.getString("type") == "clipboard.empty") return@use null
            check(response.getString("type") == "clipboard.sync")
            val text = response.getString("text")
            val seq = response.optInt("seq", 0)
            val ts = response.optLong("timestamp", 0L)
            if (seq > 0) {
                lastSeenClipboardSeq = seq
            }
            latestKnownMacClipboard = text
            RemoteClipboardInfo(text = text, seq = seq, timestamp = ts)
        }
    }

    fun pollRemoteClipboard(applyImmediately: Boolean = autoApplyMacClipboard): String? {
        if (!paired) return null
        return connect().use { channel ->
            channel.send(json("type" to "clipboard.poll", "seq" to lastSeenClipboardSeq))
            val response = channel.receive()
            if (response.getString("type") == "clipboard.empty") return@use null
            check(response.getString("type") == "clipboard.sync")
            val text = response.getString("text")
            val seq = response.optInt("seq", 0)
            if (seq > 0) {
                lastSeenClipboardSeq = seq
            }
            latestKnownMacClipboard = text
            if (applyImmediately && text != lastSentLocalClipboard && text != lastAppliedRemoteClipboard) {
                lastAppliedRemoteClipboard = text
                applyToLocalClipboard(text)
                "Synced from Mac: ${text.take(25)}"
            } else {
                null
            }
        }
    }

    fun applyToLocalClipboard(text: String) {
        Handler(Looper.getMainLooper()).post {
            try {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = ClipData.newPlainText("Companion", text)
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                    clip.description.extras = android.os.PersistableBundle().apply {
                        putBoolean(android.content.ClipDescription.EXTRA_IS_SENSITIVE, true)
                    }
                }
                clipboard.setPrimaryClip(clip)
            } catch (ignored: Exception) {}
        }
    }

    fun applyLatestMacClipboard(): String? {
        val text = latestKnownMacClipboard ?: fetchMacClipboard(force = true)?.text ?: return null
        lastAppliedRemoteClipboard = text
        applyToLocalClipboard(text)
        return text
    }

    fun getLocalClipboardText(): String? {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        if (!clipboard.hasPrimaryClip()) return null
        val item = clipboard.primaryClip?.getItemAt(0)
        return item?.coerceToText(context)?.toString()?.trim()
    }

    fun syncClipboardSmart(): String {
        check(paired) { "Not paired with Mac" }
        val localText = getLocalClipboardText()
        val localTimestamp = getLocalClipboardTimestamp()
        val macInfo = try {
            fetchMacClipboard(force = true)
        } catch (e: Exception) {
            null
        }
        val macText = macInfo?.text
        val macTimestamp = macInfo?.timestamp ?: 0L

        // 1. If both are identical, clipboards are already synchronized
        if (!localText.isNullOrBlank() && localText == macText) {
            return "Mac & Phone already in sync"
        }

        // 2. If phone has no clipboard, pull from Mac if available
        if (localText.isNullOrBlank()) {
            if (!macText.isNullOrBlank()) {
                lastAppliedRemoteClipboard = macText
                applyToLocalClipboard(macText)
                return "Pasted from Mac: ${macText.take(25)}"
            }
            return "Clipboard is empty on both devices"
        }

        // 3. If Mac has no clipboard text, push phone text to Mac
        if (macText.isNullOrBlank()) {
            syncClipboardToMac(localText, localTimestamp)
            return "Copied to Mac: ${localText.take(25)}"
        }

        // 4. Both have different non-empty text: determine direction
        val phoneWasPastedFromMac = (localText == lastAppliedRemoteClipboard)
        val phoneWasSentToMac = (localText == lastSentLocalClipboard)
        val phoneHasFreshLocalCopy = !phoneWasPastedFromMac && !phoneWasSentToMac

        val shouldPushToMac = when {
            // If phone has a fresh copy and local timestamp is newer than Mac timestamp
            localTimestamp > 0L && macTimestamp > 0L -> localTimestamp > macTimestamp
            // Fallback: if phone has fresh local copy
            phoneHasFreshLocalCopy -> true
            else -> false
        }

        return if (shouldPushToMac) {
            syncClipboardToMac(localText, localTimestamp)
            "Copied to Mac: ${localText.take(25)}"
        } else {
            lastAppliedRemoteClipboard = macText
            applyToLocalClipboard(macText)
            "Pasted from Mac: ${macText.take(25)}"
        }
    }

    fun syncCurrentClipboardToMac(): String? {
        val current = getLocalClipboardText() ?: return null
        if (current.isEmpty() || current == lastAppliedRemoteClipboard || current == lastSentLocalClipboard) {
            return null
        }
        return syncClipboardToMac(current, getLocalClipboardTimestamp())
    }

    fun receiveNextInboxItem(): String? {
        check(paired)
        return connect().use { channel ->
            channel.send(json("type" to "inbox.next"))
            val response = channel.receive()
            if (response.getString("type") == "inbox.empty") return@use null
            check(response.getString("type") == "inbox.item")
            val id = response.getString("id")
            val text = response.getString("text")
            saveInboxItem(id, text)
            channel.send(json("type" to "inbox.receipt", "id" to id))
            "Received: ${text.take(30)}"
        }
    }

    fun getInboxItems(): List<JSONObject> {
        val prefs = context.getSharedPreferences("inbox-$pin", Context.MODE_PRIVATE)
        val raw = prefs.getString("items", "[]") ?: "[]"
        val array = org.json.JSONArray(raw)
        val list = mutableListOf<JSONObject>()
        for (i in 0 until array.length()) {
            list.add(array.getJSONObject(i))
        }
        return list
    }

    fun removeInboxItem(id: String) {
        val prefs = context.getSharedPreferences("inbox-$pin", Context.MODE_PRIVATE)
        val raw = prefs.getString("items", "[]") ?: "[]"
        val array = org.json.JSONArray(raw)
        val newArray = org.json.JSONArray()
        for (i in 0 until array.length()) {
            val item = array.getJSONObject(i)
            if (item.optString("id") != id) {
                newArray.put(item)
            }
        }
        prefs.edit().putString("items", newArray.toString()).apply()
    }

    private fun saveInboxItem(id: String, text: String) {
        val prefs = context.getSharedPreferences("inbox-$pin", Context.MODE_PRIVATE)
        val raw = prefs.getString("items", "[]") ?: "[]"
        val array = org.json.JSONArray(raw)
        val item = JSONObject().apply {
            put("id", id)
            put("text", text)
            put("timestamp", System.currentTimeMillis())
            val lower = text.trim().lowercase()
            put("isLink", lower.startsWith("https://") || lower.startsWith("http://"))
        }
        val newArray = org.json.JSONArray()
        newArray.put(item)
        for (i in 0 until minOf(array.length(), 49)) {
            val existing = array.getJSONObject(i)
            if (existing.optString("id") != id && existing.optString("text") != text) {
                newArray.put(existing)
            }
        }
        prefs.edit().putString("items", newArray.toString()).apply()
    }

    data class CaptureRequestInfo(val id: String, val mode: String)

    fun pollCaptureRequest(): CaptureRequestInfo? {
        if (!paired) return null
        return connect().use { channel ->
            channel.send(json("type" to "capture.poll"))
            val response = channel.receive()
            if (response.getString("type") == "capture.empty") return@use null
            check(response.getString("type") == "capture.request")
            val id = response.getString("id")
            val mode = response.optString("mode", "photo")
            CaptureRequestInfo(id = id, mode = mode)
        }
    }

    fun dismissCaptureRequest(id: String) {
        if (!paired) return
        try {
            connect().use { channel ->
                channel.send(json("type" to "capture.dismiss", "id" to id))
                channel.receive()
            }
        } catch (ignored: Exception) {}
    }

    fun receiveNext(): String? {
        check(paired)
        return connect().use { channel ->
            channel.send(json("type" to "file.next"))
            val offer = channel.receive()
            if (offer.getString("type") == "file.empty") return@use null
            check(offer.getString("type") == "file.offer")
            val id = offer.getString("id")
            require(UUID.fromString(id).toString() == id)
            val size = offer.getLong("size")
            require(size in 0..MAX_FILE)
            val name = offer.getString("name")
            require(name.isNotEmpty() && name.toByteArray().size <= 180 && !name.contains('/') &&
                !name.contains('\\') && !name.contains('\u0000') && name != "." && name != "..")
            val expected = offer.getString("sha256")
            require(expected.matches(Regex("[0-9a-f]{64}")))
            val receipts = context.getSharedPreferences("receipts-$pin", Context.MODE_PRIVATE)
            val previous = receipts.getString(id, null)?.let { Uri.parse(it) }
            // A saved item is still consumed and verified before acknowledging a retransmission.
            val existing = previous?.takeIf { uri ->
                val savedHash = runCatching {
                    context.contentResolver.openInputStream(uri)?.use { input ->
                        val hash = MessageDigest.getInstance("SHA-256")
                        val buffer = ByteArray(65536)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            hash.update(buffer, 0, count)
                        }
                        hash.digest().joinToString("") { "%02x".format(it) }
                    }
                }.getOrNull()
                if (savedHash != null) check(savedHash == expected) { "Previously saved file was modified" }
                savedHash != null
            }
            if (existing != null) {
                channel.send(json("type" to "file.saved", "id" to id, "sha256" to expected))
                return@use "Already saved $name in Downloads/Companion"
            }

            val incomingDir = File(context.filesDir, "incoming").apply { mkdirs() }
            val partial = File(incomingDir, "$id.partial")
            var existingSize = 0L
            if (partial.exists()) {
                existingSize = partial.length()
                if (existingSize >= size) {
                    existingSize = 0L
                    partial.delete()
                }
            }
            channel.send(json("type" to "file.ready", "id" to id, "size" to existingSize))

            emitProgress(TransferProgress(id, name, TransferProgress.Direction.RECEIVE, existingSize, size, TransferProgress.State.TRANSFERRING))

            FileOutputStream(partial, true).use { file ->
                var remaining = size - existingSize
                var transferred = existingSize
                var lastEmit = System.currentTimeMillis()
                val buffer = ByteArray(65536)
                while (remaining > 0) {
                    val count = channel.input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                    if (count < 0) throw EOFException("Transfer interrupted")
                    file.write(buffer, 0, count)
                    remaining -= count
                    transferred += count
                    val now = System.currentTimeMillis()
                    if (now - lastEmit >= 200 || transferred == size) {
                        emitProgress(TransferProgress(id, name, TransferProgress.Direction.RECEIVE, transferred, size, TransferProgress.State.TRANSFERRING))
                        lastEmit = now
                    }
                }
                file.flush()
                file.fd.sync()
            }

            emitProgress(TransferProgress(id, name, TransferProgress.Direction.RECEIVE, size, size, TransferProgress.State.VERIFYING))

            val actualHash = MessageDigest.getInstance("SHA-256").let { md ->
                FileInputStream(partial).use { input ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        md.update(buffer, 0, count)
                    }
                }
                md.digest().joinToString("") { "%02x".format(it) }
            }
            check(actualHash == expected) {
                partial.delete()
                emitProgress(TransferProgress(id, name, TransferProgress.Direction.RECEIVE, 0L, size, TransferProgress.State.FAILED, "Verification failed"))
                "File verification failed"
            }

            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/Relay")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val destination = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("Could not create a Downloads file")
            var published = false
            try {
                context.contentResolver.openOutputStream(destination, "w")?.use { out ->
                    FileInputStream(partial).use { inp -> inp.copyTo(out, 65536) }
                    out.flush()
                } ?: error("Could not write destination")
                check(context.contentResolver.update(destination, ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }, null, null) == 1)
                published = true
                partial.delete()
                check(receipts.edit().putString(id, destination.toString()).commit())
                channel.send(json("type" to "file.saved", "id" to id, "sha256" to expected))
                emitProgress(TransferProgress(id, name, TransferProgress.Direction.RECEIVE, size, size, TransferProgress.State.COMPLETED))
                "Saved $name in Downloads/Relay"
            } finally {
                if (!published) {
                    context.contentResolver.delete(destination, null, null)
                    emitProgress(TransferProgress(id, name, TransferProgress.Direction.RECEIVE, 0L, size, TransferProgress.State.FAILED, "Save failed"))
                }
            }
        }
    }

    val cachedHost get() = host
    val cachedPort get() = preferences.getInt("port", 18444)

    private fun connect(): WireChannel = connectTo(host, preferences.getInt("port", 18444))

    private fun connectTo(targetHost: String, targetPort: Int, timeoutMs: Int = 10000): WireChannel {
        check(hasInvitation) { "Pair your Mac first" }
        val expectedPin = pin
        val managers = arrayOf<KeyManager>(object : X509ExtendedKeyManager() {
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = arrayOf(IDENTITY_ALIAS)
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = IDENTITY_ALIAS
            override fun chooseEngineClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, engine: SSLEngine?) = IDENTITY_ALIAS
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = null
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = null
            override fun getCertificateChain(alias: String?) = arrayOf(keyStore.getCertificate(IDENTITY_ALIAS) as X509Certificate)
            override fun getPrivateKey(alias: String?) = keyStore.getKey(IDENTITY_ALIAS, null) as PrivateKey
        })
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = throw java.security.cert.CertificateException()
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val leaf = chain?.firstOrNull() ?: throw java.security.cert.CertificateException("Missing Mac certificate")
                leaf.checkValidity()
                if (sha256(leaf.encoded) != expectedPin) throw java.security.cert.CertificateException("Mac identity changed; pair again")
                // Endpoint identity is the out-of-band certificate pin, not an IP hostname.
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(managers, arrayOf(trust), SecureRandom()) }
        val socket = tls.socketFactory.createSocket() as SSLSocket
        try {
            socket.soTimeout = 30000
            socket.enabledProtocols = socket.supportedProtocols.filter { it == "TLSv1.2" || it == "TLSv1.3" }.toTypedArray()
            socket.connect(InetSocketAddress(targetHost, targetPort), timeoutMs)
            socket.startHandshake()
            return WireChannel(socket)
        } catch (error: Exception) { socket.close(); throw error }
    }

    /**
     * Authenticates a candidate using mutual TLS and the saved certificate pin.
     * Updates the saved host only if mTLS and session.check succeed.
     * Rejects same-named services or rogue endpoints without touching stored settings.
     */
    fun verifyAndSaveCandidate(candidateHost: String, candidatePort: Int = 18444): Boolean {
        if (!hasInvitation || candidateHost.isBlank()) return false
        return try {
            connectTo(candidateHost, candidatePort, 3000).use { channel ->
                channel.send(json("type" to "session.check"))
                val resp = channel.receive()
                if (resp.optString("type") == "session.ready") {
                    preferences.edit()
                        .putString("host", candidateHost)
                        .putInt("port", candidatePort)
                        .apply()
                    true
                } else {
                    false
                }
            }
        } catch (e: Exception) {
            false
        }
    }

    fun sendNotification(notification: MirroredNotification) {
        if (!paired) return
        connect().use { channel ->
            channel.send(json(
                "type" to "notification.push",
                "id" to notification.id,
                "packageName" to notification.packageName,
                "appName" to notification.appName,
                "title" to notification.title,
                "text" to notification.text,
                "timestamp" to notification.timestamp,
                "canReply" to notification.canReply
            ))
            val resp = channel.receive()
            check(resp.getString("type") == "notification.receipt")
        }
    }

    fun sendNotificationDismiss(id: String) {
        if (!paired) return
        connect().use { channel ->
            channel.send(json("type" to "notification.dismiss", "id" to id))
            channel.receive()
        }
    }

    fun sendIncomingSms(address: String, contactName: String?, body: String, timestamp: Long) {
        if (!paired) return
        connect().use { channel ->
            channel.send(json(
                "type" to "sms.incoming",
                "address" to address,
                "contactName" to (contactName ?: address),
                "text" to body,
                "timestamp" to timestamp
            ))
            val resp = channel.receive()
            check(resp.getString("type") == "sms.receipt")
        }
    }

    fun sendCallState(state: String, number: String, callerName: String?) {
        if (!paired) return
        connect().use { channel ->
            channel.send(json(
                "type" to "call.state",
                "state" to state,
                "number" to number,
                "callerName" to (callerName ?: number),
                "timestamp" to System.currentTimeMillis()
            ))
            val resp = channel.receive()
            check(resp.getString("type") == "call.receipt")
        }
    }

    fun pollCompanionCommands() {
        if (!paired) return
        connect().use { channel ->
            channel.send(json("type" to "command.poll"))
            val response = channel.receive()
            val cmdType = response.optString("type")
            when (cmdType) {
                "notification.reply" -> {
                    val notifId = response.getString("id")
                    val replyText = response.getString("text")
                    val replyId = response.getString("replyId")
                    val ok = RelayNotificationListenerService.replyToNotification(context, notifId, replyText)
                    channel.send(json(
                        "type" to "notification.reply_ack",
                        "replyId" to replyId,
                        "status" to (if (ok) "sent" else "failed")
                    ))
                    channel.receive()
                }
                "sms.send" -> {
                    val dest = response.getString("address")
                    val body = response.getString("text")
                    val sendId = response.getString("sendId")
                    val smsHelper = SmsManagerHelper(context)
                    val ok = try {
                        smsHelper.sendSms(dest, body)
                    } catch (e: Exception) {
                        false
                    }
                    channel.send(json(
                        "type" to "sms.send_receipt",
                        "sendId" to sendId,
                        "status" to (if (ok) "sent" else "failed")
                    ))
                    channel.receive()
                }
                "sms.sync_request" -> {
                    Log.i(TAG, "Received sms.sync_request from Mac")
                    val smsHelper = SmsManagerHelper(context)
                    val conversations = smsHelper.getConversations(limit = 35)
                    val arr = org.json.JSONArray()
                    conversations.forEach { arr.put(it.toJson()) }
                    Log.i(TAG, "Sending ${conversations.size} SMS conversations (${arr.toString().length} chars) to Mac")
                    channel.send(json(
                        "type" to "sms.threads",
                        "payload" to arr.toString()
                    ))
                    val ack = channel.receive()
                    Log.i(TAG, "Mac acknowledged threads receipt: ${ack.optString("type")}")
                }
                "sms.thread_request" -> {
                    val threadId = response.getLong("threadId")
                    Log.i(TAG, "Received sms.thread_request for thread $threadId from Mac")
                    val smsHelper = SmsManagerHelper(context)
                    val messages = smsHelper.getThreadMessages(threadId, limit = 50)
                    val arr = org.json.JSONArray()
                    messages.forEach { arr.put(it.toJson()) }
                    Log.i(TAG, "Sending ${messages.size} messages for thread $threadId to Mac")
                    channel.send(json(
                        "type" to "sms.messages",
                        "threadId" to threadId,
                        "payload" to arr.toString()
                    ))
                    val ack = channel.receive()
                    Log.i(TAG, "Mac acknowledged messages receipt: ${ack.optString("type")}")
                }
                "call.answer" -> {
                    val speaker = response.optBoolean("speaker", false)
                    Log.i(TAG, "Received call.answer command from Mac (speaker=$speaker)")
                    val callController = RelayCallController(context)
                    val ok = callController.answerCall(useSpeakerphone = speaker)
                    channel.send(json(
                        "type" to "call.action_receipt",
                        "action" to "answer",
                        "status" to (if (ok) "ok" else "failed")
                    ))
                    channel.receive()
                }
                "call.speaker" -> {
                    val on = response.optBoolean("on", true)
                    Log.i(TAG, "Received call.speaker command from Mac (on=$on)")
                    val callController = RelayCallController(context)
                    callController.setSpeakerphone(on)
                    channel.send(json(
                        "type" to "call.action_receipt",
                        "action" to "speaker",
                        "status" to "ok"
                    ))
                    channel.receive()
                }
                "call.reject", "call.end" -> {
                    Log.i(TAG, "Received $cmdType command from Mac")
                    val callController = RelayCallController(context)
                    val ok = callController.endCall()
                    channel.send(json(
                        "type" to "call.action_receipt",
                        "action" to cmdType,
                        "status" to (if (ok) "ok" else "failed")
                    ))
                    channel.receive()
                }
                "call.dial" -> {
                    val number = response.optString("number")
                    Log.i(TAG, "Received call.dial command for $number from Mac")
                    val callController = RelayCallController(context)
                    val ok = callController.dialNumber(number)
                    channel.send(json(
                        "type" to "call.action_receipt",
                        "action" to "dial",
                        "number" to number,
                        "status" to (if (ok) "ok" else "failed")
                    ))
                    channel.receive()
                }
                "call.decline_with_sms" -> {
                    val number = response.optString("number")
                    val message = response.optString("message")
                    Log.i(TAG, "Received call.decline_with_sms command for $number from Mac")
                    val callController = RelayCallController(context)
                    val ok = callController.declineWithSms(number, message)
                    channel.send(json(
                        "type" to "call.action_receipt",
                        "action" to "decline_with_sms",
                        "status" to (if (ok) "ok" else "failed")
                    ))
                    channel.receive()
                }
                else -> {}
            }
        }
    }
}

private class WireChannel(private val socket: SSLSocket) : Closeable {
    val input = DataInputStream(BufferedInputStream(socket.inputStream))
    val output = DataOutputStream(BufferedOutputStream(socket.outputStream))
    fun send(message: JSONObject) {
        val data = message.toString().toByteArray(Charsets.UTF_8)
        require(data.size in 1..65536)
        output.writeInt(data.size)
        output.write(data)
        output.flush()
    }
    fun receive(): JSONObject {
        val length = input.readInt()
        require(length in 1..65536) { "Invalid control frame" }
        val data = ByteArray(length)
        input.readFully(data)
        return JSONObject(String(data, Charsets.UTF_8)).also {
            check(it.getInt("version") == 1) { "Unsupported protocol version" }
            if (it.getString("type") == "error") error(it.optString("message", "Mac rejected the request"))
        }
    }
    override fun close() { socket.close() }
}
