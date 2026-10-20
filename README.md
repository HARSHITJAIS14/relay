<div align="center">

# Relay

**A seamless, private connection between Mac and Android.**

Move files, text, clipboards, and scans between your Mac and phone as if they were one device.  
Zero accounts. Zero cloud servers. Pure encrypted local Wi-Fi.

[![Release](https://img.shields.io/badge/Release-v1.0.0-black?style=flat-square)](https://github.com/HARSHITJAIS14/relay/releases/tag/v1.0.0)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20%7C%20Android-black?style=flat-square)](#download)
[![Security](https://img.shields.io/badge/Security-mTLS%20%2B%20AES--GCM-black?style=flat-square)](#security)

</div>

---

## Downloads

| Platform | Package | Architecture / Target |
| :--- | :--- | :--- |
| **macOS** | [**Relay-v1.0.0.dmg**](https://github.com/HARSHITJAIS14/relay/releases/download/v1.0.0/Relay-v1.0.0.dmg) | macOS 13.0+ (Apple Silicon & Intel) |
| **Android** | [**Relay-v1.0.0.apk**](https://github.com/HARSHITJAIS14/relay/releases/download/v1.0.0/Relay-v1.0.0.apk) | Android 10+ (Tested through Android 16) |

---

## Features

### ⚡ Continuous Clipboard
- **Last-Write-Wins Sync**: Compares millisecond timestamps between Mac pasteboard and Android clipboard to automatically sync whichever you copied latest.
- **Quick Settings Tile**: A dedicated *"Sync Clip"* tile sits right next to Bluetooth in your phone's notification shade for 1-tap synchronization anytime.
- **Silent & Private**: Silent background caching avoids disruptive toast alerts. Sensitive clipboards (`EXTRA_IS_SENSITIVE`) are masked.

### 📤 High-Speed File Transfer
- **Mac Menu Bar Drop Zone**: Drag and drop any files onto the Relay menu bar icon to stream them directly to your phone.
- **Android Share Sheet**: Share photos, videos, or documents directly from the Gallery, Files, or any app via *"Send with Relay"*.
- **Chunk-Based Checkpoint & Resume**: If Wi-Fi blips or your laptop sleeps, Relay automatically resumes from the last byte offset and verifies whole-file SHA-256 integrity before publishing.

### 📸 Photo Capture & Multi-Page Document Scanner
- **Mac-Initiated Capture**: Tap *"📸 Take Photo"* or *"📄 Scan Document"* from your Mac menu bar to pop a camera trigger on your phone.
- **Multi-Page PDF Scanner**: Capture multiple document pages with manual edge adjustment and orientation correction, rendered directly into a scaled PDF in `Downloads/Relay`.

### 🔗 Bidirectional Text & Link Inbox
- Share URLs or snippets from Safari/Chrome without replacing your clipboard.
- Access received links and snippets in a clean, minimal inbox with 1-tap *Open*, *Copy*, or *Dismiss*.

---

## 🔒 Security & Architecture

- **Mutual TLS (mTLS)**: Every connection uses TLS 1.3 with client & server certificate verification. No device can communicate without explicit pairing consent.
- **Zero-Cloud**: Traffic never touches external servers, relay nodes, or third-party cloud infrastructure. All data travels strictly over your local Wi-Fi.
- **Instant Zero-Permission Pairing**: The Mac generates an on-screen QR invitation. The Android app uses the Google Play Code Scanner overlay (zero camera permission required) to scan the code, verify a 6-digit cryptographic SAS code, and establish mutual trust.

---

## Building from Source

### macOS App
Requires Xcode Command Line Tools and Swift 6:
```bash
cd apps/macos
swift build
python3 ../../tools/package_macos.py
# Produces Relay.app in apps/macos/.build/Relay.app
```

### Android App
Requires JDK 17 and Android SDK:
```bash
cd apps/android
./gradlew assembleDebug
# Produces app-debug.apk in apps/android/app/build/outputs/apk/debug/
```

---

## License

MIT License. Crafted with minimal monochrome aesthetics and native platform ergonomics.
