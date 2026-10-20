package dev.companion.android

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

class CaptureActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var client: PeerClient

    private var mode = "photo"
    private var captureId: String? = null

    // Photo mode
    private var currentPhotoFile: File? = null
    private var currentPhotoUri: Uri? = null

    // Scan mode
    private val scannedPages = mutableListOf<File>()
    private var statusText: TextView? = null
    private var addPageBtn: Button? = null
    private var finishScanBtn: Button? = null

    companion object {
        const val EXTRA_MODE = "extra_mode"
        const val EXTRA_CAPTURE_ID = "extra_capture_id"
        private const val REQ_PHOTO = 1001
        private const val REQ_SCAN_PAGE = 1002
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        client = PeerClient(applicationContext)

        if (!client.paired) {
            Toast.makeText(this, "Companion: Not paired with Mac", Toast.LENGTH_SHORT).show()
            finish()
            return
        }

        mode = intent.getStringExtra(EXTRA_MODE) ?: "photo"
        captureId = intent.getStringExtra(EXTRA_CAPTURE_ID)

        val draftsDir = File(filesDir, "drafts").apply { mkdirs() }

        if (mode == "photo") {
            launchPhotoCapture(draftsDir)
        } else {
            setupScanUi(draftsDir)
        }
    }

    private fun launchPhotoCapture(draftsDir: File) {
        val timeStamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val photoFile = File(draftsDir, "Photo_$timeStamp.jpg")
        currentPhotoFile = photoFile
        val authority = "${packageName}.fileprovider"
        val photoUri = FileProvider.getUriForFile(this, authority, photoFile)
        currentPhotoUri = photoUri

        val cameraIntent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, photoUri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivityForResult(cameraIntent, REQ_PHOTO)
        } catch (e: Exception) {
            Toast.makeText(this, "Camera not available: ${e.message}", Toast.LENGTH_SHORT).show()
            finish()
        }
    }

    private fun setupScanUi(draftsDir: File) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(32, 48, 32, 32)
            gravity = Gravity.CENTER_HORIZONTAL
        }

        val title = TextView(this).apply {
            text = "📄 Multi-Page Document Scanner"
            textSize = 20f
            setTypeface(null, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 16)
        }
        root.addView(title)

        statusText = TextView(this).apply {
            text = "No pages scanned yet.\nTap 'Add Page' to take a photo of document pages."
            textSize = 15f
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 32)
        }
        root.addView(statusText)

        addPageBtn = Button(this).apply {
            text = "➕ Add Page (Camera)"
            setOnClickListener {
                launchScanPageCapture(draftsDir)
            }
        }
        root.addView(addPageBtn)

        finishScanBtn = Button(this).apply {
            text = "✓ Finish & Send PDF to Mac"
            isEnabled = false
            setOnClickListener {
                compileAndSendPdf(draftsDir)
            }
        }
        root.addView(finishScanBtn)

        val cancelBtn = Button(this).apply {
            text = "Cancel"
            setOnClickListener {
                for (page in scannedPages) {
                    page.delete()
                }
                finish()
            }
        }
        root.addView(cancelBtn)

        setContentView(ScrollView(this).apply { addView(root) })

        // Auto-launch first page
        launchScanPageCapture(draftsDir)
    }

    private fun launchScanPageCapture(draftsDir: File) {
        val pageNum = scannedPages.size + 1
        val timeStamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val pageFile = File(draftsDir, "Page_${pageNum}_$timeStamp.jpg")
        currentPhotoFile = pageFile
        val authority = "${packageName}.fileprovider"
        val photoUri = FileProvider.getUriForFile(this, authority, pageFile)
        currentPhotoUri = photoUri

        val cameraIntent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, photoUri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivityForResult(cameraIntent, REQ_SCAN_PAGE)
        } catch (e: Exception) {
            Toast.makeText(this, "Camera not available: ${e.message}", Toast.LENGTH_SHORT).show()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQ_PHOTO) {
            val file = currentPhotoFile
            if (resultCode == RESULT_OK && file != null && file.exists() && file.length() > 0) {
                val displayTime = SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US).format(Date())
                val displayName = "Photo $displayTime.jpg"
                Toast.makeText(this, "Sending photo to Mac…", Toast.LENGTH_SHORT).show()

                executor.execute {
                    try {
                        client.stageFile(file, displayName)
                        captureId?.let { client.dismissCaptureRequest(it) }
                        client.sendPending()
                        handler.post {
                            Toast.makeText(this, "Photo delivered to Mac!", Toast.LENGTH_SHORT).show()
                            finish()
                        }
                    } catch (e: Exception) {
                        handler.post {
                            Toast.makeText(this, "Failed to send photo: ${e.message}", Toast.LENGTH_LONG).show()
                            finish()
                        }
                    }
                }
            } else {
                file?.delete()
                finish()
            }
        } else if (requestCode == REQ_SCAN_PAGE) {
            val file = currentPhotoFile
            if (resultCode == RESULT_OK && file != null && file.exists() && file.length() > 0) {
                scannedPages.add(file)
                statusText?.text = "Pages scanned: ${scannedPages.size}\nTap 'Add Page' for another page, or 'Finish' to send PDF."
                finishScanBtn?.isEnabled = true
                finishScanBtn?.text = "✓ Finish & Send PDF to Mac (${scannedPages.size} pages)"
            } else {
                file?.delete()
                if (scannedPages.isEmpty()) {
                    statusText?.text = "Scan cancelled. Tap 'Add Page' to retry."
                }
            }
        }
    }

    private fun compileAndSendPdf(draftsDir: File) {
        if (scannedPages.isEmpty()) {
            Toast.makeText(this, "No pages scanned", Toast.LENGTH_SHORT).show()
            return
        }

        finishScanBtn?.isEnabled = false
        addPageBtn?.isEnabled = false
        statusText?.text = "Generating PDF document (${scannedPages.size} pages)…"

        executor.execute {
            try {
                val pdfDocument = PdfDocument()
                val pageWidth = 595 // standard A4 points
                val pageHeight = 842

                for ((index, pageFile) in scannedPages.withIndex()) {
                    val bitmap = BitmapFactory.decodeFile(pageFile.absolutePath) ?: continue
                    val pageInfo = PdfDocument.PageInfo.Builder(pageWidth, pageHeight, index + 1).create()
                    val page = pdfDocument.startPage(pageInfo)
                    val canvas: Canvas = page.canvas

                    // Scale bitmap to fit within page preserving aspect ratio
                    val srcRect = Rect(0, 0, bitmap.width, bitmap.height)
                    val scale = minOf(pageWidth.toFloat() / bitmap.width, pageHeight.toFloat() / bitmap.height)
                    val destW = (bitmap.width * scale).toInt()
                    val destH = (bitmap.height * scale).toInt()
                    val left = (pageWidth - destW) / 2
                    val top = (pageHeight - destH) / 2
                    val destRect = Rect(left, top, left + destW, top + destH)

                    canvas.drawBitmap(bitmap, srcRect, destRect, null)
                    pdfDocument.finishPage(page)
                    bitmap.recycle()
                }

                val timeStamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
                val displayTime = SimpleDateFormat("yyyy-MM-dd HH.mm.ss", Locale.US).format(Date())
                val pdfFile = File(draftsDir, "Scan_$timeStamp.pdf")
                FileOutputStream(pdfFile).use { out ->
                    pdfDocument.writeTo(out)
                }
                pdfDocument.close()

                val displayName = "Scan $displayTime.pdf"
                client.stageFile(pdfFile, displayName)
                captureId?.let { client.dismissCaptureRequest(it) }
                client.sendPending()

                // Cleanup page temp images
                for (p in scannedPages) {
                    p.delete()
                }

                handler.post {
                    Toast.makeText(this, "Scan (${scannedPages.size} pages) sent to Mac!", Toast.LENGTH_SHORT).show()
                    finish()
                }
            } catch (e: Exception) {
                handler.post {
                    Toast.makeText(this, "Failed to compile scan: ${e.message}", Toast.LENGTH_LONG).show()
                    finishScanBtn?.isEnabled = true
                    addPageBtn?.isEnabled = true
                }
            }
        }
    }

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }
}
