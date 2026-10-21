package dev.companion.android

import android.app.Activity
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.widget.*
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Native dashboard for the paired Mac and everyday transfer actions. */
class MainActivity : Activity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private val working = AtomicBoolean(false)
    private lateinit var client: PeerClient
    
    // UI Elements
    private lateinit var statusPill: TextView
    private lateinit var activityStatus: TextView
    private lateinit var pairingCard: LinearLayout
    private lateinit var pairingCode: TextView
    private lateinit var invitation: EditText
    private lateinit var pair: Button
    private lateinit var scanQrBtn: Button
    
    private lateinit var heroSendCard: LinearLayout
    private lateinit var send: Button
    
    private lateinit var clipboardCard: LinearLayout
    private lateinit var clipboardSnippet: TextView
    private lateinit var syncClipboardBtn: Button
    private lateinit var getMacBtn: Button
    private lateinit var autoApplyCheck: CheckBox
    
    private lateinit var captureCard: LinearLayout
    
    private lateinit var textCard: LinearLayout
    private lateinit var textInput: EditText
    private lateinit var sendTextBtn: Button
    
    private lateinit var inboxContainer: LinearLayout
    private lateinit var footerRow: LinearLayout
    
    private var resumed = false

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (resumed && ::client.isInitialized && client.paired) {
            updateClipboardSnippetUI()
            work {
                client.syncCurrentClipboardToMac() ?: "Clipboard in sync"
            }
        }
    }

    private val poll = object : Runnable {
        override fun run() {
            if (!resumed) return
            if (::client.isInitialized && client.hasInvitation) {
                work {
                    if (!client.paired) client.pollPairing()
                    else client.sendPending() ?: client.receiveNext() ?: client.pollRemoteClipboard(applyImmediately = client.autoApplyMacClipboard) ?: client.receiveNextInboxItem() ?: client.checkConnection()
                }
            }
            handler.postDelayed(this, 3000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val density = resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#F3F4F0"))
            setPadding(dp(24), dp(24), dp(24), dp(28))
        }

        // 1. TOP HEADER WITH LOGO & MINIMAL STATUS PILL
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(20))
        }

        val logoView = ImageView(this).apply {
            setImageResource(R.drawable.ic_relay_mark)
            layoutParams = LinearLayout.LayoutParams(dp(36), dp(36)).apply {
                marginEnd = dp(12)
            }
        }
        header.addView(logoView)

        val titleView = TextView(this).apply {
            text = "Relay"
            textSize = 26f
            setTypeface(null, Typeface.BOLD)
            setTextColor(Color.parseColor("#172C29"))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        header.addView(titleView)

        statusPill = TextView(this).apply {
            text = "Starting…"
            textSize = 12f
            setTypeface(null, Typeface.BOLD)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            setBackgroundResource(R.drawable.bg_pill_disconnected)
            setTextColor(Color.parseColor("#64748B"))
        }
        header.addView(statusPill)
        root.addView(header)
        root.addView(TextView(this).apply {
            text = "Two devices. One flow."
            textSize = 30f
            setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL))
            setTextColor(Color.parseColor("#172C29"))
            setPadding(0, dp(4), 0, dp(8))
        })
        root.addView(TextView(this).apply {
            text = "Your Android, meet your Mac."
            textSize = 15f
            setTextColor(Color.parseColor("#586864"))
            setPadding(0, 0, 0, dp(24))
        })

        fun createCard(): LinearLayout {
            return LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundResource(R.drawable.bg_card)
                setPadding(dp(18), dp(18), dp(18), dp(18))
                elevation = 0f
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dp(14)
                }
            }
        }

        // 2. PAIRING CARD (Visible only when not paired)
        pairingCard = createCard().apply {
            addView(TextView(this@MainActivity).apply {
                text = "Pair with your Mac"
                textSize = 17f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setPadding(0, 0, 0, dp(4))
            })
            addView(TextView(this@MainActivity).apply {
                text = "Open Relay on your Mac. Scan its QR code, then compare the verification code on both devices."
                textSize = 13f
                setTextColor(Color.parseColor("#586864"))
                setPadding(0, 0, 0, dp(16))
            })

            scanQrBtn = Button(this@MainActivity).apply {
                text = "Scan Mac QR code"
                textSize = 14f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.WHITE)
                setBackgroundResource(R.drawable.btn_primary_black)
                setPadding(dp(16), dp(12), dp(16), dp(12))
                setOnClickListener {
                    try {
                        val scanner = com.google.mlkit.vision.codescanner.GmsBarcodeScanning.getClient(this@MainActivity)
                        scanner.startScan()
                            .addOnSuccessListener { barcode ->
                                val rawValue = barcode.rawValue
                                if (!rawValue.isNullOrBlank() && rawValue.startsWith("companion://")) {
                                    invitation.setText(rawValue)
                                    work { client.beginPairing(rawValue) }
                                } else {
                                    Toast.makeText(this@MainActivity, "Not a valid Relay pairing QR code", Toast.LENGTH_LONG).show()
                                }
                            }
                            .addOnFailureListener { e: Exception ->
                                Toast.makeText(this@MainActivity, "QR scan cancelled: ${e.message}", Toast.LENGTH_SHORT).show()
                            }
                    } catch (e: Exception) {
                        Toast.makeText(this@MainActivity, "QR Scanner error: ${e.message}", Toast.LENGTH_SHORT).show()
                    }
                }
            }
            addView(scanQrBtn)

            pairingCode = TextView(this@MainActivity).apply {
                textSize = 24f
                setTypeface(Typeface.MONOSPACE, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                gravity = Gravity.CENTER
                setPadding(0, dp(12), 0, dp(8))
            }
            addView(pairingCode)

            invitation = EditText(this@MainActivity).apply {
                hint = "Or paste pairing invitation link"
                textSize = 12f
                setTextColor(Color.parseColor("#172C29"))
                setHintTextColor(Color.parseColor("#667670"))
                setBackgroundResource(R.drawable.bg_input)
                setPadding(dp(12), dp(10), dp(12), dp(10))
                minLines = 1
                maxLines = 3
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    topMargin = dp(12)
                    bottomMargin = dp(10)
                }
            }
            addView(invitation)

            pair = Button(this@MainActivity).apply {
                text = "Pair with Link"
                textSize = 14f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setBackgroundResource(R.drawable.btn_secondary_pill)
                setOnClickListener {
                    val value = invitation.text.toString()
                    if (value.isNotBlank()) work { client.beginPairing(value) }
                }
            }
            addView(pair)
        }
        root.addView(pairingCard)

        // 3. HERO SEND FILE CARD (Primary Action)
        heroSendCard = createCard().apply {
            addView(TextView(this@MainActivity).apply {
                text = "Send to Mac"
                textSize = 17f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setPadding(0, 0, 0, dp(2))
            })
            addView(TextView(this@MainActivity).apply {
                text = "Photos, documents, and everything in between. Up to 100 MiB per file."
                textSize = 13f
                setTextColor(Color.parseColor("#586864"))
                setPadding(0, 0, 0, dp(14))
            })

            send = Button(this@MainActivity).apply {
                text = "Choose a file"
                textSize = 14f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.WHITE)
                setBackgroundResource(R.drawable.btn_primary_black)
                setPadding(dp(16), dp(13), dp(16), dp(13))
                setOnClickListener {
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        type = "*/*"
                        addCategory(Intent.CATEGORY_OPENABLE)
                    }, 10)
                }
            }
            addView(send)
        }
        root.addView(heroSendCard)

        // 4. CONTINUOUS CLIPBOARD CARD (Refined Neutral Styling)
        clipboardCard = createCard().apply {
            addView(TextView(this@MainActivity).apply {
                text = "Clipboard"
                textSize = 16f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setPadding(0, 0, 0, dp(2))
            })
            addView(TextView(this@MainActivity).apply {
                text = "Pick up where you copied off."
                textSize = 13f
                setTextColor(Color.parseColor("#586864"))
                setPadding(0, 0, 0, dp(10))
            })

            clipboardSnippet = TextView(this@MainActivity).apply {
                text = "Your next copy starts here."
                textSize = 12f
                setTextColor(Color.parseColor("#374151"))
                setBackgroundResource(R.drawable.bg_snippet)
                setPadding(dp(12), dp(10), dp(12), dp(10))
                maxLines = 2
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dp(12)
                }
            }
            addView(clipboardSnippet)

            val clipActionRow = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            }

            syncClipboardBtn = Button(this@MainActivity).apply {
                text = "Sync clipboard"
                textSize = 13f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setBackgroundResource(R.drawable.btn_secondary_pill)
                setPadding(dp(12), dp(10), dp(12), dp(10))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginEnd = dp(8)
                }
                setOnClickListener {
                    work {
                        val res = client.syncClipboardSmart()
                        updateClipboardSnippetUI()
                        res
                    }
                }
            }
            clipActionRow.addView(syncClipboardBtn)

            getMacBtn = Button(this@MainActivity).apply {
                text = "Get from Mac"
                textSize = 13f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setBackgroundResource(R.drawable.btn_secondary_pill)
                setPadding(dp(12), dp(10), dp(12), dp(10))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                setOnClickListener {
                    work {
                        val text = client.applyLatestMacClipboard()
                        updateClipboardSnippetUI()
                        if (text.isNullOrBlank()) "No new clipboard item from Mac"
                        else "Pasted from Mac: ${text.take(25)}"
                    }
                }
            }
            clipActionRow.addView(getMacBtn)
            addView(clipActionRow)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val addTileBtn = Button(this@MainActivity).apply {
                    text = "Add shortcut to Quick Settings"
                    textSize = 12f
                    setTextColor(Color.parseColor("#4B5563"))
                    setBackgroundResource(R.drawable.btn_outline)
                    setPadding(dp(12), dp(8), dp(12), dp(8))
                    layoutParams = LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                    ).apply {
                        topMargin = dp(8)
                    }
                    setOnClickListener {
                        try {
                            val statusBarManager = getSystemService(android.app.StatusBarManager::class.java)
                            statusBarManager.requestAddTileService(
                                android.content.ComponentName(this@MainActivity, CompanionTileService::class.java),
                                "Sync Clip",
                                android.graphics.drawable.Icon.createWithResource(this@MainActivity, android.R.drawable.ic_popup_sync),
                                mainExecutor
                            ) {}
                        } catch (e: Exception) {
                            Toast.makeText(this@MainActivity, "Swipe down & tap edit to add Sync Clip tile", Toast.LENGTH_LONG).show()
                        }
                    }
                }
                addView(addTileBtn)
            }

            autoApplyCheck = CheckBox(this@MainActivity).apply {
                text = "Apply Mac clipboard automatically (Android may show a popup)"
                textSize = 12f
                setTextColor(Color.parseColor("#586864"))
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    topMargin = dp(6)
                }
                setOnCheckedChangeListener { _, isChecked ->
                    if (::client.isInitialized) {
                        client.autoApplyMacClipboard = isChecked
                    }
                }
            }
            addView(autoApplyCheck)
        }
        root.addView(clipboardCard)

        // 5. CAMERA & SCANNER CARD (Refined Neutral Styling)
        captureCard = createCard().apply {
            addView(TextView(this@MainActivity).apply {
                text = "Camera & scanner"
                textSize = 16f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setPadding(0, 0, 0, dp(2))
            })
            addView(TextView(this@MainActivity).apply {
                text = "From your camera to your Mac, without the detour."
                textSize = 13f
                setTextColor(Color.parseColor("#586864"))
                setPadding(0, 0, 0, dp(12))
            })

            val captureRow = LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                )
            }

            val photoBtn = Button(this@MainActivity).apply {
                text = "Take photo"
                textSize = 13f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setBackgroundResource(R.drawable.btn_secondary_pill)
                setPadding(dp(10), dp(10), dp(10), dp(10))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                    marginEnd = dp(8)
                }
                setOnClickListener {
                    startActivity(Intent(this@MainActivity, CaptureActivity::class.java).apply {
                        putExtra(CaptureActivity.EXTRA_MODE, "photo")
                    })
                }
            }
            captureRow.addView(photoBtn)

            val scanBtn = Button(this@MainActivity).apply {
                text = "Scan PDF"
                textSize = 13f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setBackgroundResource(R.drawable.btn_secondary_pill)
                setPadding(dp(10), dp(10), dp(10), dp(10))
                layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                setOnClickListener {
                    startActivity(Intent(this@MainActivity, CaptureActivity::class.java).apply {
                        putExtra(CaptureActivity.EXTRA_MODE, "scan")
                    })
                }
            }
            captureRow.addView(scanBtn)
            addView(captureRow)
        }
        root.addView(captureCard)

        // 6. SEND LINK / TEXT CARD
        textCard = createCard().apply {
            addView(TextView(this@MainActivity).apply {
                text = "Send a thought"
                textSize = 16f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.parseColor("#172C29"))
                setPadding(0, 0, 0, dp(8))
            })

            textInput = EditText(this@MainActivity).apply {
                hint = "A link, a note, anything worth keeping…"
                textSize = 13f
                setTextColor(Color.parseColor("#172C29"))
                setHintTextColor(Color.parseColor("#667670"))
                setBackgroundResource(R.drawable.bg_input)
                setPadding(dp(14), dp(10), dp(14), dp(10))
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dp(10)
                }
            }
            addView(textInput)

            sendTextBtn = Button(this@MainActivity).apply {
                text = "Send to Mac"
                textSize = 14f
                setTypeface(null, Typeface.BOLD)
                setTextColor(Color.WHITE)
                setBackgroundResource(R.drawable.btn_primary_black)
                setOnClickListener {
                    val txt = textInput.text.toString()
                    if (txt.isNotBlank()) {
                        work {
                            val res = client.sendText(txt)
                            handler.post { textInput.text.clear() }
                            res
                        }
                    }
                }
            }
            addView(sendTextBtn)
        }
        root.addView(textCard)

        // 7. INBOX FROM MAC
        inboxContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(4), 0, dp(8))
        }
        root.addView(inboxContainer)

        // 8. FOOTER WITH RECONNECT & FORGET
        footerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(8), 0, dp(16))
            gravity = Gravity.CENTER
        }

        val reconnectBtn = Button(this).apply {
            text = "Reconnect"
            textSize = 12f
            setTextColor(Color.parseColor("#4B5563"))
            setBackgroundResource(R.drawable.btn_outline)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(8)
            }
            setOnClickListener {
                work {
                    if (client.paired) client.sendPending() ?: client.receiveNext() ?: client.pollRemoteClipboard() ?: client.receiveNextInboxItem() ?: client.checkConnection()
                    else client.pollPairing()
                }
            }
        }
        footerRow.addView(reconnectBtn)

        val forgetBtn = Button(this).apply {
            text = "Forget Mac"
            textSize = 12f
            setTextColor(Color.parseColor("#DC2626"))
            setBackgroundResource(R.drawable.btn_outline)
            setPadding(dp(12), dp(6), dp(12), dp(6))
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            setOnClickListener {
                CompanionSyncService.stop(applicationContext)
                work { client.forget(); "Mac forgotten" }
            }
        }
        footerRow.addView(forgetBtn)
        root.addView(footerRow)

        activityStatus = TextView(this).apply {
            text = "Starting Relay…"
            textSize = 13f
            setTextColor(Color.parseColor("#586864"))
            setPadding(0, dp(8), 0, dp(16))
        }
        root.addView(activityStatus)
        root.addView(TextView(this).apply {
            text = "DIRECT CONNECTION  /  NO ACCOUNT NEEDED"
            textSize = 10f
            letterSpacing = 0.08f
            setTextColor(Color.parseColor("#586864"))
        })
        // Use consistent sentence-case controls and comfortable touch targets.
        fun refineControls(view: View) {
            if (view is Button) {
                view.isAllCaps = false
                view.minHeight = dp(48)
                if (view.layoutParams?.height?.let { it in 1 until dp(48) } == true) {
                    view.layoutParams.height = dp(48)
                }
            }
            if (view is android.view.ViewGroup) {
                for (i in 0 until view.childCount) refineControls(view.getChildAt(i))
            }
        }
        refineControls(root)
        listOf(heroSendCard, clipboardCard, captureCard, textCard, footerRow).forEach { it.visibility = View.GONE }
        scanQrBtn.isEnabled = false
        pair.isEnabled = false
        setContentView(ScrollView(this).apply {
            addView(root)
            setOnApplyWindowInsetsListener { view, insets ->
                if (Build.VERSION.SDK_INT >= 30) {
                    val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars())
                    view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                }
                insets
            }
        })

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
            }
        }

        work {
            client = PeerClient(applicationContext)
            if (client.paired) {
                CompanionSyncService.start(applicationContext)
                "Mac paired"
            } else {
                "Pair your Mac once to get started."
            }
        }
    }

    private fun updateClipboardSnippetUI() {
        if (!::client.isInitialized) return
        val text = client.getLocalClipboardText()
        handler.post {
            if (text.isNullOrBlank()) {
                clipboardSnippet.text = "Phone clipboard is currently empty"
            } else {
                clipboardSnippet.text = "Clipboard: \"${text.take(35).replace('\n', ' ')}\""
            }
        }
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.addPrimaryClipChangedListener(clipListener)
        updateClipboardSnippetUI()
        refreshInboxUI()
        handler.postDelayed(poll, 1000)

        if (::client.isInitialized && client.paired) {
            CompanionSyncService.start(applicationContext)
            work {
                client.syncCurrentClipboardToMac() ?: client.pollRemoteClipboard() ?: "Mac paired"
            }
        }
    }

    override fun onPause() {
        resumed = false
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.removePrimaryClipChangedListener(clipListener)
        handler.removeCallbacks(poll)
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacks(poll)
        executor.shutdown()
        super.onDestroy()
    }

    @Deprecated("Legacy picker callback for initial native shell")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 10 && resultCode == RESULT_OK) {
            data?.data?.let { uri -> work { client.stage(uri); client.sendPending() ?: "File queued" } }
        }
    }

    private fun refreshInboxUI() {
        if (!::client.isInitialized || !client.paired) {
            inboxContainer.removeAllViews()
            return
        }
        val items = client.getInboxItems()
        inboxContainer.removeAllViews()
        if (items.isEmpty()) return

        val density = resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundResource(R.drawable.bg_card)
            setPadding(dp(18), dp(18), dp(18), dp(18))
            elevation = 0f
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                bottomMargin = dp(14)
            }
        }

        card.addView(TextView(this).apply {
            text = "Inbox from Mac (${items.size})"
            textSize = 16f
            setTypeface(null, Typeface.BOLD)
            setTextColor(Color.parseColor("#172C29"))
            setPadding(0, 0, 0, dp(10))
        })

        for (item in items) {
            val id = item.optString("id")
            val text = item.optString("text")
            val isLink = item.optBoolean("isLink", false)

            val itemBox = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundResource(R.drawable.bg_snippet)
                setPadding(dp(12), dp(10), dp(12), dp(10))
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT
                ).apply {
                    bottomMargin = dp(8)
                }
            }

            itemBox.addView(TextView(this).apply {
                this.text = text
                textSize = 13f
                setTextColor(Color.parseColor("#1F2937"))
                setTextIsSelectable(true)
            })

            val actionRow = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, dp(6), 0, 0)
            }

            if (isLink) {
                actionRow.addView(Button(this).apply {
                    isAllCaps = false
                    this.text = "Open link"
                    textSize = 11f
                    setTextColor(Color.parseColor("#172C29"))
                    setBackgroundResource(R.drawable.btn_secondary_pill)
                    layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(48)).apply {
                        marginEnd = dp(6)
                    }
                    setOnClickListener {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse(text)))
                        } catch (e: Exception) {
                            Toast.makeText(this@MainActivity, "Cannot open: ${e.message}", Toast.LENGTH_SHORT).show()
                        }
                    }
                })
            }

            actionRow.addView(Button(this).apply {
                isAllCaps = false
                this.text = "Copy"
                textSize = 11f
                setTextColor(Color.parseColor("#172C29"))
                setBackgroundResource(R.drawable.btn_secondary_pill)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(48)).apply {
                    marginEnd = dp(6)
                }
                setOnClickListener {
                    val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(android.content.ClipData.newPlainText("text", text))
                    Toast.makeText(this@MainActivity, "Copied to clipboard", Toast.LENGTH_SHORT).show()
                    updateClipboardSnippetUI()
                }
            })

            actionRow.addView(Button(this).apply {
                isAllCaps = false
                this.text = "Dismiss"
                textSize = 11f
                setTextColor(Color.parseColor("#586864"))
                setBackgroundResource(R.drawable.btn_outline)
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(48))
                setOnClickListener {
                    client.removeInboxItem(id)
                    refreshInboxUI()
                }
            })

            itemBox.addView(actionRow)
            card.addView(itemBox)
        }
        inboxContainer.addView(card)
    }

    private fun work(action: () -> String) {
        if (!working.compareAndSet(false, true)) return
        executor.execute {
            val result = runCatching(action).getOrElse { "Needs attention: ${it.message ?: it.javaClass.simpleName}" }
            handler.post {
                working.set(false)
                if (isDestroyed) return@post
                activityStatus.text = result
                
                if (::client.isInitialized) {
                    scanQrBtn.isEnabled = true
                    pair.isEnabled = true
                    autoApplyCheck.isChecked = client.autoApplyMacClipboard
                    val ready = client.paired
                    if (ready) {
                        statusPill.text = "Mac paired"
                        statusPill.setBackgroundResource(R.drawable.bg_pill_connected)
                        statusPill.setTextColor(Color.parseColor("#15803D"))
                    } else {
                        statusPill.text = "Not paired"
                        statusPill.setBackgroundResource(R.drawable.bg_pill_disconnected)
                        statusPill.setTextColor(Color.parseColor("#64748B"))
                    }

                    pairingCard.visibility = if (ready) View.GONE else View.VISIBLE
                    heroSendCard.visibility = if (ready) View.VISIBLE else View.GONE
                    captureCard.visibility = if (ready) View.VISIBLE else View.GONE
                    clipboardCard.visibility = if (ready) View.VISIBLE else View.GONE
                    textCard.visibility = if (ready) View.VISIBLE else View.GONE
                    footerRow.visibility = if (ready) View.VISIBLE else View.GONE
                    
                    if (!ready) {
                        pairingCode.text = client.pairingCode
                    }
                    refreshInboxUI()
                }
            }
        }
    }
}
