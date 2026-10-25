# Development and releases

`main` is the production branch. Its source must match the supported features in the README.
Release tags identify the exact source used for downloadable packages.

`codex/develop` is the local working branch. It preserves ongoing experiments separately
from production. Keep unpublished work local; do not push this branch or use `git push --all`.
Promote reviewed, tested changes individually to `main`, rather than merging the entire
experimental branch. Do not merge production cleanup back into development blindly.

Before a release:

1. Run `swift test -c release --package-path apps/macos`. For file-transfer changes,
   use `RUN_LARGE_TRANSFER_TESTS=1 swift test -c release --package-path apps/macos`
   to stream a full 1 GB file through the production send/receive code and verify resumption.
2. With JDK 17 and Android SDK 36 configured, run
   `./gradlew :core:test :app:assembleDebug :app:lintDebug` from `apps/android`.
3. Verify the supported features on paired devices. Keep synthetic test data out of personal messages.
4. Update Android versionName/versionCode and the Mac packaging script version together.
5. Build packages from a clean production commit and verify their versions and signatures.
6. Tag that commit, publish checksums alongside both packages, and mark the release latest.

Android v1.6.4 introduces permanent release signing and a non-debug build. Run
`python3 tools/setup_android_signing.py` once, then `:app:assembleRelease :app:lintRelease`.
The script preserves existing keys and refuses partial signing state. Securely back up the
ignored `.tooling/android-signing/` directory outside the checkout; never attach its contents
to a release. Existing debug-signed users must uninstall and pair again at this transition.
Retain the same release key for subsequent updates. Verify APK signature and certificate,
package/version metadata, and absence of the debuggable flag before publication.
Developer ID signing/notarization and Google Play distribution require separate setup.

Mac preview signing uses a persistent certificate in `.tooling/macos-signing/`. Retain and
securely back up this ignored folder; it contains a private signing key and generated password.
Never commit or attach its contents to a release. `tools/setup_dev_signing.py` is idempotent.
The packager temporarily opens that build-only keychain for signing and restores the original
Keychain search list afterward. It does not install a trusted root. For public distribution,
configure an Apple Developer ID identity and notarization separately.

Icon artwork comes from `assets/relay-mark.svg`. Run `swift tools/generate_icons.swift`
on macOS to regenerate Mac, Android, header and menu-bar resources, then check the preview.
