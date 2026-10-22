<div align="center">

![Relay: Your Mac. Your Android. Finally, on speaking terms.](assets/relay-banner.svg)

**You bought a Mac. You didn't sign up to buy an iPhone.**

Relay brings your Android into your Mac workflow. Send a file, grab a clipboard,
reply to SMS, and see your phone’s notifications on your Mac.
Your devices talk directly over local Wi-Fi.

[Download v1.6.2](https://github.com/HARSHITJAIS14/relay/releases/tag/v1.6.2) · [Get started](#get-started) · [Build from source](#build-from-source)

</div>

## Keep the phone you like

An ecosystem should connect the devices you chose. Relay is a small, native bridge
between macOS and Android, with no account and no cloud relay for your transfers.

| When you need to… | Use Relay to… |
| --- | --- |
| Get a photo or document onto the other device | Send from Android's share sheet, or choose/drop a file in the Mac window or menu bar panel. |
| Move something you copied | Tap **Sync** on the phone’s notification card to send or receive clipboard content. The Android app and **Sync Clip** Quick Settings tile are also available. |
| Reply to a message notification from your Mac | Mirror WhatsApp, Telegram, or Messages notifications and send inline replies directly from Mac. |
| Text from your computer | Browse your phone's SMS threads, view message bubbles, and compose new SMS messages from Mac. |
| Save a link without losing your clipboard | Send it to the other device's text and link inbox. |
| Get a paper document onto your Mac | Capture a photo or scan multiple pages into a PDF on your phone. You can request capture from your Mac. |

## Get started

1. Install Relay on your Mac and Android phone. Put both devices on the same local network.
2. Open Relay on your Mac, then choose **Scan Mac QR code** on Android.
3. Compare the verification codes on both devices and approve pairing on your Mac.
4. Send a file, mirror notifications, browse SMS, or sync your clipboard.

Received files go to `Downloads/Relay`. Open the Mac's received-files button to jump there.
QR scanning uses Google Play services; you can also paste a pairing invitation link.

## Downloads & current status

[Download v1.6.2](https://github.com/HARSHITJAIS14/relay/releases/tag/v1.6.2), featuring file transfers, one-tap clipboard sync, SMS, and notification mirroring.

| Platform | Package |
| --- | --- |
| macOS (Apple Silicon) | [Relay-v1.6.2.dmg](https://github.com/HARSHITJAIS14/relay/releases/download/v1.6.2/Relay-v1.6.2.dmg) |
| Android | [Relay-v1.6.2.apk](https://github.com/HARSHITJAIS14/relay/releases/download/v1.6.2/Relay-v1.6.2.apk) |

### Included in v1.6.2

- **Files:** send in either direction, with preparation feedback, live percentage and byte counts, reconnection, and integrity checks.
- **Clipboard:** one **Sync** action handles sending and receiving. No direction picker.
- **SMS:** browse conversations and compose messages on Mac through your paired phone.
- **Notifications:** mirror phone notifications and reply where the originating app supports inline replies.
- **Native navigation:** Transfer, Messages, and Notifications on Mac.

SMS requires Android permission and your phone’s cellular service; carrier charges may apply.
Notification mirroring requires Android notification access. Inline replies depend on the source app.

Relay is an early project. Current limits are part of the deal:

- **1 GB per file (1,000,000,000 bytes).** Transfers use checkpoints and verify the complete file with SHA-256 before saving it.
- **Local network required.** Guest Wi-Fi, client isolation, firewalls, and sleeping devices can prevent connections.
- **Clipboard access depends on Android.** Use the app, share sheet, or Quick Settings tile when background clipboard access is restricted. Applying Mac clipboard updates automatically is an optional Android setting.
- **Build targets:** macOS 13+ and Android 10+. Existing device testing covers an Apple Silicon Mac and an Android 16 phone; that does not establish compatibility with every supported OS or Intel Macs.
- **Development distribution:** the Mac preview uses a persistent local signing identity, and the Android build below produces a debug APK. These are not notarized Mac or Play Store releases.

## Secure connection approval on Mac

Relay stores its private device-connection key in Keychain as **Relay secure device connection**.
If macOS needs permission to use that key, Relay first explains the request and waits for you
to select **Continue**. Enter your Mac password only in the macOS Keychain dialog; Relay does
not receive that password. An upgrade from an older preview may require one approval while
preserving the same device identity and pairing. Declining leaves the connection paused.

## Private by design

Pairing requires explicit approval and matching verification codes. Paired devices use
mutual TLS and pinned certificate identities. The implementation permits TLS 1.2 and
TLS 1.3; transferred files are checked with SHA-256.

Relay's transfer path is device-to-device on your local network. There is no Relay account,
cloud inbox, or hosted transfer server. This is a description of the implementation,
not a claim of an independent security audit.

## Build from source

### macOS

Install Xcode Command Line Tools with a Swift 6 toolchain, then run from the repository root:

```sh
swift test --package-path apps/macos
python3 tools/setup_dev_signing.py  # once, for a persistent preview signing identity
python3 tools/package_macos.py
open apps/macos/.build/Relay.app
```

The bundle is built for the host architecture. Set `RELAY_SIGNING_IDENTITY` to a Developer ID
identity for distribution. Preview builds use a persistent signing identity in the ignored
`.tooling/macos-signing/` folder; keep that folder private and retain it across builds.
The packager requires consistent signing. `--allow-adhoc` is available only for disposable
local builds and may cause repeated Keychain prompts. Preview signing is not notarization.

### Android

Install JDK 17 and Android SDK platform 36. Set `JAVA_HOME` and `ANDROID_HOME` for your installation, then:

```sh
cd apps/android
./gradlew :core:test :app:assembleDebug
```

The APK is written to `apps/android/app/build/outputs/apk/debug/app-debug.apk`.

## Where Relay goes next

The next priorities are broader device testing, signed installation packages, and a
short real-device demo. Remote internet transfers are not currently supported.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the production and development workflow.

Found a rough edge? [Open an issue](https://github.com/HARSHITJAIS14/relay/issues)
with your OS versions, what you tried, and what happened. Keep personal clipboard contents
and pairing invitations out of reports.

## License

MIT. See [LICENSE](LICENSE).
